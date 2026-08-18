#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>

typedef BOOL (*PresentRenderbufferImplementation)(id, SEL, NSUInteger);
typedef void (*SetDrawablePropertiesImplementation)(id, SEL, NSDictionary *);
typedef id (*InitWithLayerImplementation)(id, SEL, id);

static PresentRenderbufferImplementation OriginalPresentRenderbuffer;
static SetDrawablePropertiesImplementation OriginalSetDrawableProperties;
static InitWithLayerImplementation OriginalInitWithLayer;
static _Atomic(uint64_t) PresentedFrameCount;
static id LastDrawableLayer;
static BOOL SparkControllerHooksInstalled;
static pthread_mutex_t LastDrawableLayerMutex = PTHREAD_MUTEX_INITIALIZER;

static NSString *const RetainedBackingKey =
    @"kEAGLDrawablePropertyRetainedBacking";
static NSString *const ColorFormatKey =
    @"kEAGLDrawablePropertyColorFormat";
static NSString *const RGBA8ColorFormat = @"kEAGLColorFormatRGBA8";

static NSDictionary *RetainedDrawableProperties(NSDictionary *properties) {
    NSMutableDictionary *updated = properties != nil
        ? [properties mutableCopy]
        : [NSMutableDictionary new];
    updated[RetainedBackingKey] = @YES;
    updated[ColorFormatKey] = RGBA8ColorFormat;
    return updated;
}

static void ApplyRetainedBacking(id layer) {
    if (layer == nil) {
        return;
    }

    SEL setProperties = sel_registerName("setDrawableProperties:");
    if ([layer respondsToSelector:setProperties]) {
        NSDictionary *properties = RetainedDrawableProperties(nil);
        ((void (*)(id, SEL, id))objc_msgSend)(layer, setProperties, properties);
    }

    SEL setOpaque = @selector(setOpaque:);
    if ([layer respondsToSelector:setOpaque]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, setOpaque, YES);
    }
}

static void ApplyRetainedBackingToViewController(id controller) {
    SEL viewSelector = @selector(view);
    if (![controller respondsToSelector:viewSelector]) {
        return;
    }

    id view = ((id (*)(id, SEL))objc_msgSend)(controller, viewSelector);
    SEL layerSelector = @selector(layer);
    if (![view respondsToSelector:layerSelector]) {
        return;
    }

    CALayer *rootLayer = ((id (*)(id, SEL))objc_msgSend)(view, layerSelector);
    ApplyRetainedBacking(rootLayer);
    for (CALayer *layer in rootLayer.sublayers) {
        ApplyRetainedBacking(layer);
    }
}

static BOOL PresentRenderbuffer(id self, SEL selector, NSUInteger target) {
    uint64_t frame = atomic_fetch_add_explicit(
        &PresentedFrameCount,
        1,
        memory_order_relaxed) + 1;
    if (frame % 10 == 1) {
        SEL currentDrawable = sel_registerName("currentDrawable");
        if ([self respondsToSelector:currentDrawable]) {
            id drawable = ((id (*)(id, SEL))objc_msgSend)(
                self,
                currentDrawable);
            ApplyRetainedBacking(drawable);
        }
    }
    return OriginalPresentRenderbuffer(self, selector, target);
}

static void SetDrawableProperties(
    id self,
    SEL selector,
    NSDictionary *properties) {
    OriginalSetDrawableProperties(
        self,
        selector,
        RetainedDrawableProperties(properties));
    pthread_mutex_lock(&LastDrawableLayerMutex);
    LastDrawableLayer = self;
    pthread_mutex_unlock(&LastDrawableLayerMutex);
}

static id InitWithLayer(id self, SEL selector, id layer) {
    id initialized = OriginalInitWithLayer(self, selector, layer);
    ApplyRetainedBacking(initialized);
    return initialized;
}

static void InstallSparkControllerHooks(void) {
    if (SparkControllerHooksInstalled) {
        return;
    }

    Class controller = NSClassFromString(@"SparkViewController");
    if (controller == Nil) {
        return;
    }

    Method didAppear = class_getInstanceMethod(
        controller,
        @selector(viewDidAppear:));
    if (didAppear != NULL) {
        IMP original = method_getImplementation(didAppear);
        IMP replacement = imp_implementationWithBlock(^(id self, BOOL animated) {
            ((void (*)(id, SEL, BOOL))original)(
                self,
                @selector(viewDidAppear:),
                animated);
            ApplyRetainedBackingToViewController(self);
        });
        // Spark inherits this method; the verified fix requires the shared owner.
        method_setImplementation(didAppear, replacement);
    }

    Method didLayout = class_getInstanceMethod(
        controller,
        @selector(viewDidLayoutSubviews));
    if (didLayout != NULL) {
        IMP original = method_getImplementation(didLayout);
        IMP replacement = imp_implementationWithBlock(^(id self) {
            ((void (*)(id, SEL))original)(
                self,
                @selector(viewDidLayoutSubviews));
            ApplyRetainedBackingToViewController(self);
        });
        method_setImplementation(didLayout, replacement);
    }

    SparkControllerHooksInstalled = didAppear != NULL || didLayout != NULL;
}

static IMP ReplaceMethod(
    Class target,
    SEL selector,
    IMP replacement) {
    Method method = class_getInstanceMethod(target, selector);
    if (method == NULL) {
        return NULL;
    }
    return method_setImplementation(method, replacement);
}

__attribute__((constructor))
static void InstallRetainedBackingFix(void) {
    OriginalPresentRenderbuffer = (PresentRenderbufferImplementation)ReplaceMethod(
        NSClassFromString(@"EAGLContext"),
        sel_registerName("presentRenderbuffer:"),
        (IMP)PresentRenderbuffer);
    OriginalSetDrawableProperties =
        (SetDrawablePropertiesImplementation)ReplaceMethod(
        NSClassFromString(@"CAEAGLLayer"),
        sel_registerName("setDrawableProperties:"),
        (IMP)SetDrawableProperties);
    OriginalInitWithLayer = (InitWithLayerImplementation)ReplaceMethod(
        NSClassFromString(@"CAEAGLLayer"),
        @selector(initWithLayer:),
        (IMP)InitWithLayer);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
        dispatch_get_main_queue(),
        ^{ InstallSparkControllerHooks(); });
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{
            InstallSparkControllerHooks();
            pthread_mutex_lock(&LastDrawableLayerMutex);
            id lastDrawableLayer = LastDrawableLayer;
            pthread_mutex_unlock(&LastDrawableLayerMutex);
            ApplyRetainedBacking(lastDrawableLayer);
        });
}
