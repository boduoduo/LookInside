#if defined(SHOULD_COMPILE_LOOKIN_SERVER) && (TARGET_OS_IPHONE || TARGET_OS_TV || TARGET_OS_VISION || TARGET_OS_MAC)
//
//  LKS_RequestHandler.h
//  LookinServer
//
//  Created by Li Kai on 2019/1/15.
//  https://lookin.work
//

#import <Foundation/Foundation.h>

@class Lookin_PTChannel;

/// One handler instance per accepted connection. The handler holds a weak
/// reference to its bound channel and sends every response and push
/// directly through that channel, so requests from one client never leak
/// into another client's response stream.
@interface LKS_RequestHandler : NSObject

/// Bind this handler to a specific connected channel. The handler keeps
/// the channel weakly so the connection manager remains the owner of the
/// channel lifecycle.
- (instancetype)initWithChannel:(Lookin_PTChannel *)channel;

/// The channel this handler responds on. May become nil if the connection
/// has been torn down before a deferred response fires.
@property(nonatomic, weak, readonly) Lookin_PTChannel *boundChannel;

- (BOOL)canHandleRequestType:(uint32_t)requestType;

- (void)handleRequestType:(uint32_t)requestType tag:(uint32_t)tag object:(id)object;

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
