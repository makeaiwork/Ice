//
//  NativeMenuBarBridge.m
//  Ice
//
// Runtime bridge adapted from teddychan/ice-2 (GPL-3.0), September 2026.
// https://github.com/teddychan/ice-2/tree/main/Ice/MenuBar/Native

#import "NativeMenuBarBridge.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <objc/message.h>

// The upstream bridge credits runtime research in fif7y/pelmet (GPL-3.0).
// https://github.com/fif7y/pelmet
BOOL ICENativeMenuBarAvailable(void) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY);
    });
    Class config = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
    return framework &&
        [config instancesRespondToSelector:NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:")] &&
        [assertion instancesRespondToSelector:NSSelectorFromString(@"activateWithConfiguration:completionHandler:")] &&
        [assertion instancesRespondToSelector:NSSelectorFromString(@"invalidate")];
}

void ICENativeMenuBarInvalidate(id assertion) {
    @try {
        SEL selector = NSSelectorFromString(@"invalidate");
        if ([assertion respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, selector);
        }
    } @catch (NSException *exception) {
        NSLog(@"Ice native menu bar invalidation failed: %@", exception.reason);
    }
}

id ICENativeMenuBarActivate(NSArray<NSNumber *> *systemItems, NSArray<NSString *> *bundles,
                          void (^completion)(NSError *)) {
    if (!ICENativeMenuBarAvailable()) return nil;
    id assertion = nil;
    @try {
        id configuration = ((id (*)(id, SEL, id, id))objc_msgSend)(
            [NSClassFromString(@"MBAssessmentModeConfiguration") alloc],
            NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:"), systemItems, bundles);
        assertion = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        if (!configuration || !assertion) return nil;
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(assertion,
            NSSelectorFromString(@"activateWithConfiguration:completionHandler:"), configuration, completion);
        return assertion;
    } @catch (NSException *exception) {
        ICENativeMenuBarInvalidate(assertion);
        NSLog(@"Ice native menu bar activation failed: %@", exception.reason);
        return nil;
    }
}
