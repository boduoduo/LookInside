#if defined(SHOULD_COMPILE_LOOKIN_SERVER)
//
//  Lookin.h
//  Lookin
//
//  Created by Li Kai on 2018/8/5.
//  https://lookin.work
//

#import "TargetConditionals.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#elif TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

/// Posted when a connected peer channel ends. The notification's
/// `object` is the `Lookin_PTChannel` instance that just closed, so
/// observers can scope their cancellation logic to *their* channel and
/// ignore unrelated clients disconnecting.
extern NSString *const LKS_ConnectionDidEndNotificationName;

@class LookinConnectionResponseAttachment;
@class Lookin_PTChannel;

@interface LKS_ConnectionManager : NSObject

+ (instancetype)sharedInstance;

@property(nonatomic, assign) BOOL applicationIsActive;

/// Push an unsolicited frame to *every* currently-connected peer.
///
/// The original API targeted a single peer. With multiple clients we
/// broadcast: the only call site historically was a UI hint
/// (`LookinPush_BringForwardScreenshotTask`) which is harmless to send
/// to every connected client. If a future push needs targeted routing,
/// add a channel parameter at that point.
- (void)pushData:(NSObject *)data type:(uint32_t)type;

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
