#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef id (*InitWithStringImplementation)(id, SEL, NSString *);

static InitWithStringImplementation OriginalInitWithString;

static NSString *StringOrEmpty(NSString *value) {
    return value ?: @"";
}

static id InitWithNonNilString(id self, SEL selector, NSString *value) {
    return OriginalInitWithString(self, selector, StringOrEmpty(value));
}

__attribute__((constructor))
static void InstallNilStringFix(void) {
    // Other concrete NSString classes can use incompatible initializer IMPs.
    Class placeholderString = NSClassFromString(@"NSPlaceholderString");
    Method initializer = class_getInstanceMethod(
        placeholderString,
        @selector(initWithString:));

    if (initializer == NULL) {
        return;
    }

    OriginalInitWithString = (InitWithStringImplementation)
        method_setImplementation(initializer, (IMP)InitWithNonNilString);
}
