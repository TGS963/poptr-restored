#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

// Spark2 save records: this magic header, a big-endian u16 name length, the
// ASCII field name, then a type tag (0x01 bool, 0x03 big-endian double).
// Worked out from hex dumps of a real save; anything that doesn't match this
// shape exactly is left untouched.
static const uint8_t SaveHeader[] = {0x8e, 0x04, 0x00, 0x00};
static NSString *const BackupSuffix = @".poptr-restored-backup";
static NSString *const ErrorDomain = @"org.poptr-restored.SaveUnlock";
static NSString *const StateDirectoryName = @"org.poptr-restored";
static NSString *const FailureMarkerName = @"UnlockError-v1";
static NSString *const SuccessMarkerName = @"UnlockComplete-v1";

typedef NS_ENUM(NSInteger, UnlockResult) {
    UnlockResultNotReady,
    UnlockResultApplied,
    UnlockResultFatal
};

@interface SaveUpdate : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSData *data;
@property(nonatomic, copy) NSData *original;
@end

@implementation SaveUpdate
@end

static NSString *DocumentsDirectory(void) {
    return [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory,
        NSUserDomainMask,
        YES) firstObject];
}

static NSString *UnlockStateDirectory(void) {
    NSString *applicationSupport = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory,
        NSUserDomainMask,
        YES) firstObject];
    NSString *stateDirectory =
        [applicationSupport stringByAppendingPathComponent:StateDirectoryName];
    [NSFileManager.defaultManager createDirectoryAtPath:stateDirectory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return stateDirectory;
}

static NSString *SuccessMarkerPath(NSString *stateDirectory) {
    return [stateDirectory stringByAppendingPathComponent:SuccessMarkerName];
}

static NSString *FailureMarkerPath(NSString *stateDirectory) {
    return [stateDirectory stringByAppendingPathComponent:FailureMarkerName];
}

static BOOL UnlockHasCompleted(NSString *stateDirectory) {
    return [NSFileManager.defaultManager fileExistsAtPath:
        SuccessMarkerPath(stateDirectory)];
}

// A fresh install has no save profile until the player reaches the menu, so
// back off quickly at first, then settle into a slow poll for as long as the
// game stays open.
static NSTimeInterval RetryDelay(NSUInteger attempt) {
    static const NSTimeInterval Delays[] = {2, 4, 8, 16};
    return attempt < sizeof(Delays) / sizeof(Delays[0])
        ? Delays[attempt]
        : 30;
}

static void ClearFailureMarker(NSString *stateDirectory) {
    [NSFileManager.defaultManager removeItemAtPath:
        FailureMarkerPath(stateDirectory) error:nil];
}

static NSError *UnlockError(NSString *message) {
    return [NSError errorWithDomain:ErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSData *SaveHash(NSData *data) {
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static NSData *BooleanSave(NSString *field, BOOL value) {
    NSData *name = [field dataUsingEncoding:NSASCIIStringEncoding];
    if (name == nil || name.length > UINT16_MAX) {
        return nil;
    }

    NSMutableData *save = [NSMutableData dataWithBytes:SaveHeader
                                                length:sizeof(SaveHeader)];
    uint16_t length = CFSwapInt16HostToBig((uint16_t)name.length);
    [save appendBytes:&length length:sizeof(length)];
    [save appendData:name];
    const uint8_t taggedValue[] = {0x01, value ? 0x01 : 0x00};
    [save appendBytes:taggedValue length:sizeof(taggedValue)];
    return save;
}

static NSNumber *ExactBooleanValue(NSData *save, NSString *field) {
    NSData *falseSave = BooleanSave(field, NO);
    if ([save isEqualToData:falseSave]) {
        return @NO;
    }
    NSData *trueSave = BooleanSave(field, YES);
    return [save isEqualToData:trueSave] ? @YES : nil;
}

static NSData *SaveByReplacingExactDouble(
    NSData *original,
    NSString *field,
    double value,
    NSError **error) {
    NSData *name = [field dataUsingEncoding:NSASCIIStringEncoding];
    NSUInteger expectedLength = sizeof(SaveHeader) + 2 + name.length + 1 + 8;
    const uint8_t *bytes = original.bytes;
    if (name == nil || original.length != expectedLength ||
        memcmp(bytes, SaveHeader, sizeof(SaveHeader)) != 0) {
        if (error != NULL) {
            *error = UnlockError([NSString stringWithFormat:
                @"%@ has an unexpected record shape", field]);
        }
        return nil;
    }

    NSUInteger nameLengthOffset = sizeof(SaveHeader);
    uint16_t storedLength = ((uint16_t)bytes[nameLengthOffset] << 8) |
        bytes[nameLengthOffset + 1];
    NSUInteger nameOffset = nameLengthOffset + 2;
    NSUInteger typeOffset = nameOffset + name.length;
    if (storedLength != name.length ||
        memcmp(bytes + nameOffset, name.bytes, name.length) != 0 ||
        bytes[typeOffset] != 0x03) {
        if (error != NULL) {
            *error = UnlockError([NSString stringWithFormat:
                @"%@ is not the expected double record", field]);
        }
        return nil;
    }

    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    bits = CFSwapInt64HostToBig(bits);
    NSMutableData *updated = [original mutableCopy];
    [updated replaceBytesInRange:NSMakeRange(typeOffset + 1, sizeof(bits))
                       withBytes:&bits];
    return updated;
}

static NSData *ReadValidatedPair(
    NSString *dataPath,
    NSString *hashPath,
    NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:dataPath options:0 error:error];
    if (data == nil) {
        return nil;
    }

    NSData *storedHash = [NSData dataWithContentsOfFile:hashPath
                                               options:0
                                                 error:error];
    if (storedHash.length != CC_SHA1_DIGEST_LENGTH ||
        ![storedHash isEqualToData:SaveHash(data)]) {
        if (error != NULL) {
            *error = UnlockError([NSString stringWithFormat:
                @"%@ has a missing or invalid SHA-1 sidecar",
                dataPath.lastPathComponent]);
        }
        return nil;
    }
    return data;
}

static NSData *ReadValidatedSave(NSString *path, NSError **error) {
    return ReadValidatedPair(
        path,
        [path stringByAppendingString:@".hash"],
        error);
}

static BOOL EnsureBackupPair(NSString *path, NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *hashPath = [path stringByAppendingString:@".hash"];
    NSString *dataBackup = [path stringByAppendingString:BackupSuffix];
    NSString *hashBackup = [hashPath stringByAppendingString:BackupSuffix];
    BOOL hasDataBackup = [files fileExistsAtPath:dataBackup];
    BOOL hasHashBackup = [files fileExistsAtPath:hashBackup];
    if (hasDataBackup != hasHashBackup) {
        if (error != NULL) {
            *error = UnlockError([NSString stringWithFormat:
                @"%@ has an incomplete backup pair",
                path.lastPathComponent]);
        }
        return NO;
    }
    if (hasDataBackup) {
        return ReadValidatedPair(dataBackup, hashBackup, error) != nil;
    }

    if (![files copyItemAtPath:path toPath:dataBackup error:error]) {
        return NO;
    }
    if (![files copyItemAtPath:hashPath toPath:hashBackup error:error]) {
        [files removeItemAtPath:dataBackup error:nil];
        [files removeItemAtPath:hashBackup error:nil];
        return NO;
    }
    if (ReadValidatedPair(dataBackup, hashBackup, error) == nil) {
        [files removeItemAtPath:dataBackup error:nil];
        [files removeItemAtPath:hashBackup error:nil];
        return NO;
    }
    return YES;
}

static BOOL WriteSavePair(NSString *path, NSData *data, NSError **error) {
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    NSString *hashPath = [path stringByAppendingString:@".hash"];
    return [SaveHash(data) writeToFile:hashPath
                               options:NSDataWritingAtomic
                                 error:error];
}

// O_EXCL so we can never clobber a record the game created between our
// existence check and the write.
static BOOL WriteExclusiveFile(
    NSString *path,
    NSData *data,
    NSError **error) {
    int descriptor = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (descriptor < 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:nil];
        }
        return NO;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(descriptor, bytes, remaining);
        if (written <= 0) {
            int writeError = errno;
            close(descriptor);
            unlink(path.fileSystemRepresentation);
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:writeError
                                         userInfo:nil];
            }
            return NO;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    if (close(descriptor) != 0) {
        int closeError = errno;
        unlink(path.fileSystemRepresentation);
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:closeError
                                     userInfo:nil];
        }
        return NO;
    }
    return YES;
}

static BOOL WriteNewSavePair(
    NSString *path,
    NSData *data,
    BOOL *created,
    NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    *created = NO;
    if (!WriteExclusiveFile(path, data, error)) {
        return NO;
    }
    *created = YES;
    NSString *hashPath = [path stringByAppendingString:@".hash"];
    if (!WriteExclusiveFile(hashPath, SaveHash(data), error)) {
        if ([files removeItemAtPath:path error:nil]) {
            *created = NO;
        }
        return NO;
    }
    return YES;
}

static BOOL RollBackUpdate(SaveUpdate *update, NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *hashPath = [update.path stringByAppendingString:@".hash"];
    if (update.original == nil) {
        BOOL dataRemoved = ![files fileExistsAtPath:update.path] ||
            [files removeItemAtPath:update.path error:error];
        BOOL hashRemoved = ![files fileExistsAtPath:hashPath] ||
            [files removeItemAtPath:hashPath error:error];
        return dataRemoved && hashRemoved;
    }

    if (!WriteSavePair(update.path, update.original, error)) {
        return NO;
    }
    NSData *restored = ReadValidatedSave(update.path, error);
    return restored != nil && [restored isEqualToData:update.original];
}

static BOOL ApplyUpdates(
    NSArray<SaveUpdate *> *updates,
    NSError **error) {
    for (SaveUpdate *update in updates) {
        if (update.original != nil &&
            !EnsureBackupPair(update.path, error)) {
            return NO;
        }
    }

    NSMutableArray<SaveUpdate *> *applied = [NSMutableArray array];
    for (SaveUpdate *update in updates) {
        BOOL created = NO;
        BOOL written = update.original != nil
            ? WriteSavePair(update.path, update.data, error)
            : WriteNewSavePair(update.path, update.data, &created, error);
        if (!written) {
            NSError *writeError = error != NULL ? *error : nil;
            if (update.original != nil || created) {
                [applied addObject:update];
            }
            NSError *rollbackError = nil;
            BOOL rolledBack = YES;
            for (SaveUpdate *rollback in applied.reverseObjectEnumerator) {
                if (!RollBackUpdate(rollback, &rollbackError)) {
                    rolledBack = NO;
                }
            }
            if (error != NULL) {
                *error = rolledBack
                    ? writeError
                    : UnlockError([NSString stringWithFormat:
                        @"write failed and rollback failed: %@",
                        rollbackError.localizedDescription ?: @"unknown error"]);
            }
            return NO;
        }
        [applied addObject:update];
    }
    return YES;
}

static SaveUpdate *CurrencyUpdate(
    NSString *path,
    NSString *field,
    double value,
    NSError **error) {
    NSData *original = ReadValidatedSave(path, error);
    if (original == nil) {
        return nil;
    }
    NSData *updated = SaveByReplacingExactDouble(
        original,
        field,
        value,
        error);
    if (updated == nil) {
        return nil;
    }

    SaveUpdate *update = [SaveUpdate new];
    update.path = path;
    update.data = updated;
    update.original = original;
    return update;
}

static BOOL PlanCharacterUpdate(
    NSString *path,
    NSData *unlocked,
    NSMutableArray<SaveUpdate *> *updates,
    NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:path]) {
        if ([files fileExistsAtPath:[path stringByAppendingString:@".hash"]]) {
            if (error != NULL) {
                *error = UnlockError([NSString stringWithFormat:
                    @"%@ has an orphaned SHA-1 sidecar",
                    path.lastPathComponent]);
            }
            return NO;
        }
        SaveUpdate *update = [SaveUpdate new];
        update.path = path;
        update.data = unlocked;
        [updates addObject:update];
        return YES;
    }

    NSData *existing = ReadValidatedSave(path, error);
    if (existing == nil) {
        return NO;
    }
    NSNumber *bought = ExactBooleanValue(existing, @"BoughtCharacter");
    if (bought == nil) {
        if (error != NULL) {
            *error = UnlockError([NSString stringWithFormat:
                @"%@ is not a recognized character record",
                path.lastPathComponent]);
        }
        return NO;
    }
    if (bought.boolValue) {
        return YES;
    }

    SaveUpdate *update = [SaveUpdate new];
    update.path = path;
    update.data = unlocked;
    update.original = existing;
    [updates addObject:update];
    return YES;
}

static UnlockResult ApplyUnlock(NSError **error) {
    NSString *documents = DocumentsDirectory();
    NSString *cosmos = [documents stringByAppendingPathComponent:@"Cosmos/1"];
    NSString *shop = [cosmos stringByAppendingPathComponent:@"Shop"];
    NSString *statistics = [cosmos stringByAppendingPathComponent:@"Statistics"];
    NSArray<NSString *> *currencyPaths = @[
        [statistics stringByAppendingPathComponent:@"GameCrystals"],
        [statistics stringByAppendingPathComponent:@"TotalGameCrystals"],
        [statistics stringByAppendingPathComponent:@"GameTokens"]
    ];
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:shop]) {
        return UnlockResultNotReady;
    }
    for (NSString *path in currencyPaths) {
        if (![files fileExistsAtPath:path] ||
            ![files fileExistsAtPath:[path stringByAppendingString:@".hash"]]) {
            return UnlockResultNotReady;
        }
    }

    SaveUpdate *crystals = CurrencyUpdate(
        currencyPaths[0], @"GameCrystals", 99999.0, error);
    SaveUpdate *totalCrystals = CurrencyUpdate(
        currencyPaths[1], @"TotalGameCrystals", 99999.0, error);
    SaveUpdate *tokens = CurrencyUpdate(
        currencyPaths[2], @"GameTokens", 9999.0, error);
    if (crystals == nil || totalCrystals == nil || tokens == nil) {
        return UnlockResultFatal;
    }

    NSMutableArray<SaveUpdate *> *updates = [NSMutableArray arrayWithObjects:
        crystals,
        totalCrystals,
        tokens,
        nil];
    NSData *unlocked = BooleanSave(@"BoughtCharacter", YES);
    for (NSInteger prince = 2; prince <= 12; ++prince) {
        NSString *name = [NSString stringWithFormat:@"Prince_%ld", (long)prince];
        if (!PlanCharacterUpdate(
                [shop stringByAppendingPathComponent:name],
                unlocked,
                updates,
                error)) {
            return UnlockResultFatal;
        }
    }
    if (!ApplyUpdates(updates, error)) {
        return UnlockResultFatal;
    }

    NSString *stateDirectory = UnlockStateDirectory();
    NSString *marker = SuccessMarkerPath(stateDirectory);
    [@"Currency and character skins unlocked.\n"
        writeToFile:marker
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
    ClearFailureMarker(stateDirectory);
    return UnlockResultApplied;
}

static void WriteFailureMarker(NSError *error) {
    NSString *path = FailureMarkerPath(UnlockStateDirectory());
    [[error.localizedDescription stringByAppendingString:@"\n"]
        writeToFile:path
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
}

static void ScheduleUnlockAttempt(NSUInteger attempt) {
    NSTimeInterval delay = RetryDelay(attempt);
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            NSString *stateDirectory = UnlockStateDirectory();
            if (UnlockHasCompleted(stateDirectory)) {
                ClearFailureMarker(stateDirectory);
                return;
            }

            NSError *error = nil;
            UnlockResult result = ApplyUnlock(&error);
            if (result == UnlockResultFatal) {
                WriteFailureMarker(error ?: UnlockError(@"unlock failed"));
            } else if (result == UnlockResultNotReady) {
                ScheduleUnlockAttempt(attempt + 1);
            }
        });
}

__attribute__((constructor))
static void InstallSaveUnlock(void) {
    ScheduleUnlockAttempt(0);
}
