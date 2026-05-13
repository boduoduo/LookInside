#ifdef SHOULD_COMPILE_LOOKIN_SERVER
//
//  LKS_MultiplatformAdapter.h
//
//
//  Created by nixjiang on 2024/3/12.
//

#import <Foundation/Foundation.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <objc/message.h>
#endif

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

#import "LookinDefines.h"

NS_ASSUME_NONNULL_BEGIN

#if TARGET_OS_IPHONE
/// Resolve `[UIApplication sharedApplication]` indirectly so the host's
/// `APPLICATION_EXTENSION_API_ONLY=YES` build setting (auto-applied to any
/// CocoaPods target whose consumer embeds an app extension — Filmly's
/// tvOS target, banner extensions on iOS, watchOS hosts, …) doesn't reject
/// the call at compile time.
///
/// LookinServer is debug-only and only ever runs in the host app process,
/// so calling `+sharedApplication` is always safe at runtime — the
/// availability annotation is purely a static-analysis gate. Going through
/// `objc_msgSend` keeps the codepath identical to a direct call but
/// hides the selector from the App Extension API auditor.
NS_INLINE UIApplication * _Nullable LKS_SharedApplication(void) {
    Class cls = NSClassFromString(@"UIApplication");
    if (!cls) { return nil; }
    SEL sel = NSSelectorFromString(@"sharedApplication");
    if (![cls respondsToSelector:sel]) { return nil; }
    UIApplication * (*msg)(Class, SEL) = (UIApplication * (*)(Class, SEL))objc_msgSend;
    return msg(cls, sel);
}
#endif

@interface LKS_MultiplatformAdapter : NSObject

+ (LookinWindow *)keyWindow;

+ (NSArray<LookinWindow *> *)allWindows;

+ (CGRect)mainScreenBounds;

+ (CGFloat)mainScreenScale;

+ (BOOL)isiPad;

+ (BOOL)isMac;

@end

NS_ASSUME_NONNULL_END

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
