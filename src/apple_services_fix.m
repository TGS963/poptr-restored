#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <dlfcn.h>
#include <stdlib.h>

typedef void (^LegacyAuthenticationCompletion)(NSError *);
typedef void (^AuthenticationHandler)(id, NSError *);

static BOOL IsSubclassOfClass(Class candidate, Class ancestor) {
    for (Class current = candidate;
         current != Nil;
         current = class_getSuperclass(current)) {
        if (current == ancestor) {
            return YES;
        }
    }
    return NO;
}

static BOOL ReplaceInstanceMethod(Class target, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(target, selector);
    if (method == NULL) {
        return NO;
    }

    // Adding an override also covers internal subclasses that inherit the API.
    class_replaceMethod(
        target,
        selector,
        replacement,
        method_getTypeEncoding(method));
    return YES;
}

static unsigned int ReplaceMethodOnClassTree(
    Class root,
    SEL selector,
    IMP replacement) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    unsigned int replacementCount = 0;

    for (unsigned int index = 0; index < classCount; ++index) {
        Class candidate = classes[index];
        if (IsSubclassOfClass(candidate, root) &&
            ReplaceInstanceMethod(candidate, selector, replacement)) {
            ++replacementCount;
        }
    }

    free(classes);
    return replacementCount;
}

static NSError *DisabledServiceError(void) {
    return [NSError errorWithDomain:@"org.poptr-restored.ServiceDisabled"
                               code:1
                           userInfo:@{
        NSLocalizedDescriptionKey:
            @"This discontinued online service is disabled."
    }];
}

static void RejectLegacyAuthentication(
    id self,
    SEL selector,
    LegacyAuthenticationCompletion completion) {
    (void)self;
    (void)selector;
    if (completion != nil) {
        completion(DisabledServiceError());
    }
}

static void RejectAuthenticationHandler(
    id self,
    SEL selector,
    AuthenticationHandler handler) {
    (void)self;
    (void)selector;
    if (handler != nil) {
        handler(nil, DisabledServiceError());
    }
}

static void IgnoreOperation(id self, SEL selector) {
    (void)self;
    (void)selector;
}

static void IgnoreOperationWithObject(id self, SEL selector, id object) {
    (void)self;
    (void)selector;
    (void)object;
}

static unsigned int DisableGameCenter(void) {
    Class localPlayer = objc_getClass("GKLocalPlayer");
    if (localPlayer == Nil) {
        return 0;
    }

    unsigned int count = 0;
    count += ReplaceMethodOnClassTree(
        localPlayer,
        sel_registerName("authenticateWithCompletionHandler:"),
        (IMP)RejectLegacyAuthentication);
    count += ReplaceMethodOnClassTree(
        localPlayer,
        sel_registerName("setAuthenticateHandler:"),
        (IMP)RejectAuthenticationHandler);
    return count;
}

static unsigned int DisableStoreKit(void) {
    unsigned int count = 0;
    Class receiptRequest = objc_getClass("SKReceiptRefreshRequest");
    if (receiptRequest != Nil) {
        count += ReplaceMethodOnClassTree(
            receiptRequest,
            sel_registerName("start"),
            (IMP)IgnoreOperation);
    }

    Class paymentQueue = objc_getClass("SKPaymentQueue");
    if (paymentQueue == Nil) {
        return count;
    }

    const char *selectors[] = {
        "addTransactionObserver:",
        "addPayment:",
        "restoreCompletedTransactionsWithApplicationUsername:"
    };
    const size_t selectorCount = sizeof(selectors) / sizeof(selectors[0]);
    for (size_t index = 0; index < selectorCount; ++index) {
        count += ReplaceMethodOnClassTree(
            paymentQueue,
            sel_registerName(selectors[index]),
            (IMP)IgnoreOperationWithObject);
    }

    count += ReplaceMethodOnClassTree(
        paymentQueue,
        sel_registerName("restoreCompletedTransactions"),
        (IMP)IgnoreOperation);
    return count;
}

__attribute__((constructor))
static void InstallAppleServicesFix(void) {
    @autoreleasepool {
        dlopen(
            "/System/Library/Frameworks/GameKit.framework/GameKit",
            RTLD_LAZY | RTLD_LOCAL);
        dlopen(
            "/System/Library/Frameworks/StoreKit.framework/StoreKit",
            RTLD_LAZY | RTLD_LOCAL);

        NSLog(
            @"[PoPTR] disabled %u Game Center and %u StoreKit methods",
            DisableGameCenter(),
            DisableStoreKit());
    }
}
