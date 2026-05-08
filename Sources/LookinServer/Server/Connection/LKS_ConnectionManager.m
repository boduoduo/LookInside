#if defined(SHOULD_COMPILE_LOOKIN_SERVER)
//
//  LookinServer.m
//  LookinServer
//
//  Created by Li Kai on 2018/8/5.
//  https://lookin.work
//

#import "LKS_ConnectionManager.h"
#import "Lookin_PTChannel.h"
#import "LKS_RequestHandler.h"
#import "LookinConnectionAttachment.h"
#import "LookinConnectionResponseAttachment.h"
#import "LKS_ExportManager.h"
#import "LookinServerDefines.h"
#import "LKS_TraceManager.h"
#import "LKS_MultiplatformAdapter.h"

NSString *const LKS_ConnectionDidEndNotificationName = @"LKS_ConnectionDidEndNotificationName";

@interface LKS_ConnectionManager () <Lookin_PTChannelDelegate>

/// The single listening socket. Always in the `listening` state once
/// the manager has found a free port; never converted into a connected
/// channel because peertalk hands accept()-ed peers off as fresh
/// `Lookin_PTChannel` instances (see `Lookin_PTChannel.m:382-454`).
@property(nonatomic, strong) Lookin_PTChannel *listeningChannel_;

/// All currently-connected peer channels. The collection is keyed
/// strongly so the manager owns each connection until it ends; on
/// `didEndWithError:` we remove the closing channel and let it
/// deallocate naturally.
///
/// Each channel stores its bound `LKS_RequestHandler` in
/// `channel.userInfo` so the request path is fully self-routing — we
/// never need to look up which handler belongs to which channel.
@property(nonatomic, strong) NSMutableSet<Lookin_PTChannel *> *peerChannels_;

@end

@implementation LKS_ConnectionManager

+ (instancetype)sharedInstance {
    static LKS_ConnectionManager *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[LKS_ConnectionManager alloc] init];
    });
    return sharedInstance;
}

+ (void)load {
    // 触发 init 方法
    [LKS_ConnectionManager sharedInstance];
}

- (instancetype)init {
    if (self = [super init]) {
        NSLog(@"LookinServer - Will launch. Framework version: %@", LOOKIN_SERVER_READABLE_VERSION);

        _peerChannels_ = [NSMutableSet set];

#if TARGET_OS_IPHONE
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleApplicationDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleWillResignActiveNotification) name:UIApplicationWillResignActiveNotification object:nil];
#endif

#if TARGET_OS_OSX
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleApplicationDidBecomeActive) name:NSApplicationDidBecomeActiveNotification object:nil];
//        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleWillResignActiveNotification) name:NSApplicationWillResignActiveNotification object:nil];
#endif

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleLocalInspect:) name:@"Lookin_2D" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleLocalInspect:) name:@"Lookin_3D" object:nil];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"Lookin_Export" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            [[LKS_ExportManager sharedInstance] exportAndShare];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"Lookin_RelationSearch" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            [[LKS_TraceManager sharedInstance] addSearchTarger:note.object];
        }];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleGetLookinInfo:) name:@"GetLookinInfo" object:nil];

#if TARGET_OS_OSX
        self.applicationIsActive = YES;
        [self _searchPortToListenIfNotListening];
#endif
    }
    return self;
}

- (void)_handleWillResignActiveNotification {
    self.applicationIsActive = NO;

    // Tear down a stalled listening socket if the app is being suspended;
    // active connections are left alone so background reflection can
    // still respond if iOS lets us.
    if (self.listeningChannel_ && ![self.listeningChannel_ isListening]) {
        [self.listeningChannel_ close];
        self.listeningChannel_ = nil;
    }
}

- (void)_handleApplicationDidBecomeActive {
    self.applicationIsActive = YES;
    [self _searchPortToListenIfNotListening];
}

/// Find a free port and start listening on it. Idempotent: if we are
/// already listening, this is a no-op. Triggered on launch, after the
/// app comes back to foreground, and if the listening socket dies on
/// us for any reason (rare).
///
/// Note: we deliberately do *not* reset on every connection accept the
/// way the original code did — the listening fd survives accept() and
/// keeps yielding new peers, so there is nothing to reset.
- (void)_searchPortToListenIfNotListening {
    if (self.listeningChannel_ && self.listeningChannel_.isListening) {
        NSLog(@"LookinServer - Abort to search ports. Already listening on %@.", self.listeningChannel_.debugTag);
        return;
    }
    NSLog(@"LookinServer - Searching port to listen...");
    [self.listeningChannel_ close];
    self.listeningChannel_ = nil;

#if TARGET_OS_OSX
    [self _tryToListenOnPortFrom:LookinMacIPv4PortNumberStart to:LookinMacIPv4PortNumberEnd current:LookinMacIPv4PortNumberStart];
#else
    if ([self isiOSAppOnMac]) {
        [self _tryToListenOnPortFrom:LookinSimulatorIPv4PortNumberStart to:LookinSimulatorIPv4PortNumberEnd current:LookinSimulatorIPv4PortNumberStart];
    } else {
        [self _tryToListenOnPortFrom:LookinUSBDeviceIPv4PortNumberStart to:LookinUSBDeviceIPv4PortNumberEnd current:LookinUSBDeviceIPv4PortNumberStart];
    }
#endif
}

- (BOOL)isiOSAppOnMac {
#if TARGET_OS_SIMULATOR
    return YES;
#elif TARGET_OS_OSX
    return YES;
#else
    if (@available(iOS 14.0, *)) {
        // isiOSAppOnMac 这个 API 看似在 iOS 14.0 上可用，但其实在 iOS 14 beta 上是不存在的、有 unrecognized selector 问题，因此这里要用 respondsToSelector 做一下保护
        NSProcessInfo *info = [NSProcessInfo processInfo];
        if ([info respondsToSelector:@selector(isiOSAppOnMac)] && [info isiOSAppOnMac]) {
            return YES;
        } else if ([info respondsToSelector:@selector(isMacCatalystApp)] && [info isMacCatalystApp]) {
            return YES;
        } else {
            return NO;
        }
    } else if (@available(iOS 13.0, tvOS 13.0, *)) {
        return [NSProcessInfo processInfo].isMacCatalystApp;
    }
    return NO;
#endif
}

- (void)_tryToListenOnPortFrom:(int)fromPort to:(int)toPort current:(int)currentPort  {
    Lookin_PTChannel *channel = [Lookin_PTChannel channelWithDelegate:self];
    channel.targetPort = currentPort;
    [channel listenOnPort:currentPort IPv4Address:INADDR_LOOPBACK callback:^(NSError *error) {
        if (error) {
            if (error.code == 48) {
                // 该地址已被占用
            } else {
                // 未知失败
            }

            if (currentPort < toPort) {
                // 尝试下一个端口
                NSLog(@"LookinServer - 127.0.0.1:%d is unavailable(%@). Will try anothor address ...", currentPort, error);
                [self _tryToListenOnPortFrom:fromPort to:toPort current:(currentPort + 1)];
            } else {
                // 所有端口都尝试完毕，全部失败
                NSLog(@"LookinServer - 127.0.0.1:%d is unavailable(%@).", currentPort, error);
                NSLog(@"LookinServer - Connect failed in the end.");
            }

        } else {
            // 成功
            NSLog(@"LookinServer - Listening on 127.0.0.1:%d with channel %@.", currentPort, channel.debugTag);
            self.listeningChannel_ = channel;
        }
    }];
}

- (void)dealloc {
    [self.listeningChannel_ close];
    for (Lookin_PTChannel *channel in self.peerChannels_.copy) {
        [channel close];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Push (broadcast to all peers)

- (void)pushData:(NSObject *)data type:(uint32_t)type {
    if (self.peerChannels_.count == 0) {
        return;
    }
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:data];
    dispatch_data_t payload = [archived createReferencingDispatchData];
    for (Lookin_PTChannel *channel in self.peerChannels_.copy) {
        [channel sendFrameOfType:type tag:0 withPayload:payload callback:^(NSError *error) {}];
    }
}

#pragma mark - Lookin_PTChannelDelegate

- (BOOL)ioFrameChannel:(Lookin_PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
    LKS_RequestHandler *handler = [self _handlerForChannel:channel];
    if (!handler) {
        // Frame on a channel we don't know about — refuse and let the
        // channel tear itself down.
        return NO;
    }
    if ([handler canHandleRequestType:type]) {
        return YES;
    }
    [channel close];
    return NO;
}

- (void)ioFrameChannel:(Lookin_PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(Lookin_PTData*)payload {
    LKS_RequestHandler *handler = [self _handlerForChannel:channel];
    if (!handler) {
        return;
    }

    id object = nil;
    if (payload) {
        id unarchivedObject = [NSKeyedUnarchiver unarchiveObjectWithData:[NSData dataWithContentsOfDispatchData:payload.dispatchData]];
        if ([unarchivedObject isKindOfClass:[LookinConnectionAttachment class]]) {
            LookinConnectionAttachment *attachment = (LookinConnectionAttachment *)unarchivedObject;
            object = attachment.data;
        } else {
            object = unarchivedObject;
        }
    }
    [handler handleRequestType:type tag:tag object:object];
}

/// Called by peertalk's listening channel for every accepted peer.
/// We append the new channel to `peerChannels_` rather than replacing
/// any existing peer — this is what enables multiple simultaneous
/// clients (GUI + 1+ CLI sessions). Each channel gets its own
/// request handler so per-connection state (paginated streams,
/// pending detail jobs, future caches) is naturally isolated.
- (void)ioFrameChannel:(Lookin_PTChannel*)channel didAcceptConnection:(Lookin_PTChannel*)otherChannel fromAddress:(Lookin_PTAddress*)address {
    NSLog(@"LookinServer - channel:%@ accepted connection:%@ from %@. peers=%lu",
          channel.debugTag, otherChannel.debugTag, address,
          (unsigned long)(self.peerChannels_.count + 1));

    otherChannel.targetPort = channel.targetPort;

    // Attach a per-connection handler. Stored on `userInfo` (peertalk
    // reserves this field for client use) so frame routing in
    // `didReceiveFrameOfType:` is O(1).
    LKS_RequestHandler *handler = [[LKS_RequestHandler alloc] initWithChannel:otherChannel];
    otherChannel.userInfo = handler;

    [self.peerChannels_ addObject:otherChannel];
}

/// Routes a closing channel either to the listening-recovery path or
/// to the peer-cleanup path.
///
/// - If the listening socket dies, we restart port discovery so new
///   clients can attach again. Existing connected peers keep working
///   on their own sockets.
/// - If a connected peer dies, we remove it from `peerChannels_` and
///   post `LKS_ConnectionDidEndNotificationName` with the peer
///   channel as the notification object so per-channel observers
///   (e.g. `LKS_HierarchyDetailsHandler`) can scope their teardown.
- (void)ioFrameChannel:(Lookin_PTChannel*)channel didEndWithError:(NSError*)error {
    if (channel == self.listeningChannel_) {
        NSLog(@"LookinServer - Listening channel %@ ended (%@). Reattempting port search.",
              channel.debugTag, error);
        self.listeningChannel_ = nil;
        [self _searchPortToListenIfNotListening];
        return;
    }

    if ([self.peerChannels_ containsObject:channel]) {
        NSLog(@"LookinServer - Peer channel %@ ended (%@). peers=%lu",
              channel.debugTag, error,
              (unsigned long)(self.peerChannels_.count - 1));
        // Snapshot the channel before removing so observers can compare
        // against `notification.object`.
        [[NSNotificationCenter defaultCenter] postNotificationName:LKS_ConnectionDidEndNotificationName
                                                            object:channel];
        channel.userInfo = nil;  // release the bound handler
        [self.peerChannels_ removeObject:channel];
        return;
    }

    // Unknown channel (already removed, or pre-`didAcceptConnection`
    // listening channel that peertalk cancelled internally). Ignore.
    NSLog(@"LookinServer - Ignore channel%@ end.", channel.debugTag);
}

#pragma mark - Helpers

- (LKS_RequestHandler *)_handlerForChannel:(Lookin_PTChannel *)channel {
    id userInfo = channel.userInfo;
    if ([userInfo isKindOfClass:[LKS_RequestHandler class]]) {
        return (LKS_RequestHandler *)userInfo;
    }
    return nil;
}

#pragma mark - Handler

- (void)_handleLocalInspect:(NSNotification *)note {
#if TARGET_OS_IPHONE
    UIAlertController  *alertController = [UIAlertController  alertControllerWithTitle:@"Lookin" message:@"Failed to run local inspection. The feature has been removed. Please use the computer version of Lookin or consider SDKs like FLEX for similar functionality."  preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction  = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alertController addAction:okAction];
    UIWindow *keyWindow = [LKS_MultiplatformAdapter keyWindow];
    UIViewController *rootViewController = [keyWindow rootViewController];
    [rootViewController presentViewController:alertController animated:YES completion:nil];

#elif TARGET_OS_OSX
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Lookin";
    alert.informativeText = @"Failed to run local inspection. The feature has been removed. Please use the computer version of Lookin or consider SDKs like FLEX for similar functionality.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
#endif
    NSLog(@"LookinServer - Failed to run local inspection. The feature has been removed. Please use the computer version of Lookin or consider SDKs like FLEX for similar functionality.");
}

- (void)handleGetLookinInfo:(NSNotification *)note {
    NSDictionary* userInfo = note.userInfo;
    if (!userInfo) {
        return;
    }
    NSMutableDictionary* infoWrapper = userInfo[@"infos"];
    if (![infoWrapper isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"LookinServer - GetLookinInfo failed. Params invalid.");
        return;
    }
    infoWrapper[@"lookinServerVersion"] = LOOKIN_SERVER_READABLE_VERSION;
}

@end

/// 这个类使得用户可以通过 NSClassFromString(@"Lookin") 来判断 LookinServer 是否被编译进了项目里

@interface Lookin : NSObject

@end

@implementation Lookin

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
