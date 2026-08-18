#import <Foundation/Foundation.h>

#include <assert.h>

#import "../src/save_unlock.m"

static NSData *DoubleSave(NSString *field, double value) {
    NSData *name = [field dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *save = [NSMutableData dataWithBytes:SaveHeader
                                                length:sizeof(SaveHeader)];
    uint16_t length = CFSwapInt16HostToBig((uint16_t)name.length);
    [save appendBytes:&length length:sizeof(length)];
    [save appendData:name];
    uint8_t type = 0x03;
    [save appendBytes:&type length:sizeof(type)];
    uint64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    bits = CFSwapInt64HostToBig(bits);
    [save appendBytes:&bits length:sizeof(bits)];
    return save;
}

static double DoubleValue(NSData *save, NSString *field) {
    NSUInteger offset = sizeof(SaveHeader) + 2 + field.length + 1;
    uint64_t bits = 0;
    [save getBytes:&bits range:NSMakeRange(offset, sizeof(bits))];
    bits = CFSwapInt64BigToHost(bits);
    double value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static NSString *TemporaryDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSUUID UUID].UUIDString];
    assert([NSFileManager.defaultManager createDirectoryAtPath:path
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:nil]);
    return path;
}

static void WriteValidatedPair(NSString *path, NSData *data) {
    assert([data writeToFile:path atomically:YES]);
    assert([SaveHash(data) writeToFile:
        [path stringByAppendingString:@".hash"] atomically:YES]);
}

static void TestSerialization(void) {
    const uint8_t expectedTrue[] = {
        0x8e, 0x04, 0x00, 0x00, 0x00, 0x0f,
        'B', 'o', 'u', 'g', 'h', 't', 'C', 'h', 'a', 'r', 'a', 'c', 't', 'e', 'r',
        0x01, 0x01
    };
    NSData *trueSave = BooleanSave(@"BoughtCharacter", YES);
    assert([trueSave isEqualToData:
        [NSData dataWithBytes:expectedTrue length:sizeof(expectedTrue)]]);
    assert(ExactBooleanValue(trueSave, @"BoughtCharacter").boolValue);
    assert(!ExactBooleanValue(
        BooleanSave(@"BoughtCharacter", NO),
        @"BoughtCharacter").boolValue);

    NSError *error = nil;
    NSData *updated = SaveByReplacingExactDouble(
        DoubleSave(@"GameCrystals", 5.0),
        @"GameCrystals",
        99999.0,
        &error);
    assert(updated != nil && error == nil);
    assert(DoubleValue(updated, @"GameCrystals") == 99999.0);

    error = nil;
    assert(SaveByReplacingExactDouble(
        DoubleSave(@"GameCrystals", 5.0),
        @"GameTokens",
        9999.0,
        &error) == nil);
    assert(error != nil);
}

static void TestHashValidation(void) {
    NSString *directory = TemporaryDirectory();
    NSString *path = [directory stringByAppendingPathComponent:@"save"];
    NSData *data = DoubleSave(@"GameTokens", 2.0);
    WriteValidatedPair(path, data);

    NSError *error = nil;
    assert([ReadValidatedSave(path, &error) isEqualToData:data]);
    assert(error == nil);

    assert([@"bad" writeToFile:[path stringByAppendingString:@".hash"]
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:nil]);
    error = nil;
    assert(ReadValidatedSave(path, &error) == nil);
    assert(error != nil);
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

static void TestCharacterPlanning(void) {
    NSString *directory = TemporaryDirectory();
    NSData *unlocked = BooleanSave(@"BoughtCharacter", YES);
    NSMutableArray<SaveUpdate *> *updates = [NSMutableArray array];
    NSError *error = nil;

    NSString *missing = [directory stringByAppendingPathComponent:@"Prince_2"];
    assert(PlanCharacterUpdate(missing, unlocked, updates, &error));
    assert(updates.count == 1 && updates[0].original == nil);

    NSString *alreadyUnlocked =
        [directory stringByAppendingPathComponent:@"Prince_3"];
    WriteValidatedPair(alreadyUnlocked, unlocked);
    assert(PlanCharacterUpdate(alreadyUnlocked, unlocked, updates, &error));
    assert(updates.count == 1);

    NSString *locked = [directory stringByAppendingPathComponent:@"Prince_4"];
    WriteValidatedPair(locked, BooleanSave(@"BoughtCharacter", NO));
    assert(PlanCharacterUpdate(locked, unlocked, updates, &error));
    assert(updates.count == 2 && updates[1].original != nil);
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

static void TestTransactionRollback(void) {
    NSString *directory = TemporaryDirectory();
    NSString *existing = [directory stringByAppendingPathComponent:@"currency"];
    NSData *original = DoubleSave(@"GameCrystals", 5.0);
    WriteValidatedPair(existing, original);

    SaveUpdate *first = [SaveUpdate new];
    first.path = existing;
    first.original = original;
    first.data = DoubleSave(@"GameCrystals", 99999.0);

    SaveUpdate *failure = [SaveUpdate new];
    failure.path = [directory stringByAppendingPathComponent:@"missing/save"];
    failure.data = BooleanSave(@"BoughtCharacter", YES);

    NSError *error = nil;
    assert(!ApplyUpdates(@[first, failure], &error));
    assert(error != nil);
    assert([[NSData dataWithContentsOfFile:existing] isEqualToData:original]);
    assert(ReadValidatedSave(existing, nil) != nil);

    NSString *created = [directory stringByAppendingPathComponent:@"Prince_2"];
    SaveUpdate *newRecord = [SaveUpdate new];
    newRecord.path = created;
    newRecord.data = BooleanSave(@"BoughtCharacter", YES);
    error = nil;
    assert(!ApplyUpdates(@[newRecord, failure], &error));
    assert(![NSFileManager.defaultManager fileExistsAtPath:created]);
    assert(![NSFileManager.defaultManager fileExistsAtPath:
        [created stringByAppendingString:@".hash"]]);
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

static void TestRetryPolicy(void) {
    assert(RetryDelay(0) == 2);
    assert(RetryDelay(1) == 4);
    assert(RetryDelay(2) == 8);
    assert(RetryDelay(3) == 16);
    assert(RetryDelay(4) == 30);
    assert(RetryDelay(100) == 30);

    NSString *stateDirectory = TemporaryDirectory();
    assert(SuccessMarkerPath(stateDirectory).pathExtension.length == 0);
    assert(FailureMarkerPath(stateDirectory).pathExtension.length == 0);
    assert(!UnlockHasCompleted(stateDirectory));
    assert([@"done\n" writeToFile:SuccessMarkerPath(stateDirectory)
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:nil]);
    assert(UnlockHasCompleted(stateDirectory));

    assert([@"old error\n" writeToFile:FailureMarkerPath(stateDirectory)
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:nil]);
    ClearFailureMarker(stateDirectory);
    assert(![NSFileManager.defaultManager fileExistsAtPath:
        FailureMarkerPath(stateDirectory)]);
    [NSFileManager.defaultManager removeItemAtPath:stateDirectory error:nil];
}

int main(void) {
    @autoreleasepool {
        TestSerialization();
        TestHashValidation();
        TestCharacterPlanning();
        TestTransactionRollback();
        TestRetryPolicy();
    }
    return 0;
}
