#import <Foundation/Foundation.h>

#include <pthread.h>

static NSString *const LogFileName = @"PoPTR-Restored.log";
static NSUncaughtExceptionHandler *PreviousExceptionHandler;
static pthread_mutex_t LogMutex = PTHREAD_MUTEX_INITIALIZER;

static NSString *LogFilePath(void) {
    NSString *documents = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Documents"];
    return [documents stringByAppendingPathComponent:LogFileName];
}

static NSString *TimestampedLine(NSString *message) {
    return [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
}

static void WriteLog(NSString *message, BOOL append) {
    if (pthread_mutex_trylock(&LogMutex) != 0) {
        return;
    }

    @try {
        NSData *line = [TimestampedLine(message)
            dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = LogFilePath();
        NSFileManager *files = NSFileManager.defaultManager;

        if (!append || ![files fileExistsAtPath:path]) {
            [line writeToFile:path atomically:YES];
            return;
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:line];
        [handle closeFile];
    } @finally {
        pthread_mutex_unlock(&LogMutex);
    }
}

static void AppendLog(NSString *message) {
    WriteLog(message, YES);
}

static void RecordUncaughtException(NSException *exception) {
    @try {
        NSString *stack = [exception.callStackSymbols
            componentsJoinedByString:@"\n"];
        AppendLog([NSString stringWithFormat:
            @"uncaught exception %@: %@\n%@",
            exception.name,
            exception.reason,
            stack]);
    } @catch (NSException *loggingException) {
        (void)loggingException;
    }

    if (PreviousExceptionHandler != NULL &&
        PreviousExceptionHandler != RecordUncaughtException) {
        PreviousExceptionHandler(exception);
    }
}

static void RecordNotification(NSString *name) {
    [NSNotificationCenter.defaultCenter
        addObserverForName:name
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        AppendLog([@"notification " stringByAppendingString:notification.name]);
    }];
}

__attribute__((constructor))
static void InstallDiagnostics(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        WriteLog([NSString stringWithFormat:
            @"loaded bundle=%@ version=%@ os=%@",
            bundle.bundleIdentifier,
            [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
            NSProcessInfo.processInfo.operatingSystemVersionString], NO);

        PreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(RecordUncaughtException);

        RecordNotification(@"UIApplicationDidFinishLaunchingNotification");
        RecordNotification(@"UIApplicationDidBecomeActiveNotification");
        RecordNotification(@"UIApplicationDidEnterBackgroundNotification");
        RecordNotification(@"UIApplicationDidReceiveMemoryWarningNotification");
        RecordNotification(@"UIApplicationWillTerminateNotification");
    }
}
