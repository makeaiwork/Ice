//
//  NativeMenuBarBridge.h
//  Ice
//
// Runtime bridge adapted from teddychan/ice-2 (GPL-3.0), September 2026.
// https://github.com/teddychan/ice-2/tree/main/Ice/MenuBar/Native


#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
BOOL ICENativeMenuBarAvailable(void);
id _Nullable ICENativeMenuBarActivate(NSArray<NSNumber *> *systemItems,
                                    NSArray<NSString *> *bundles,
                                    void (^completion)(NSError * _Nullable));
void ICENativeMenuBarInvalidate(id _Nullable assertion);
NS_ASSUME_NONNULL_END
