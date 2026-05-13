#if defined(SHOULD_COMPILE_LOOKIN_SERVER)
//
//  LKS_RequestHandler.m
//  LookinServer
//
//  Created by Li Kai on 2019/1/15.
//  https://lookin.work
//

#import "LKS_RequestHandler.h"
#import "LKS_ConnectionManager.h"
#import "Lookin_PTChannel.h"
#import "LookinConnectionResponseAttachment.h"
#import "LookinHierarchyInfo.h"
#import "LookinAppInfo.h"
#import "LookinObject.h"
#import "LookinDisplayItemDetail.h"
#import "LookinStaticAsyncUpdateTask.h"
#import "NSObject+LookinServer.h"
#import "LKS_AttrGroupsMaker.h"
#import "LKS_IntrospectionHandler.h"
#import <objc/message.h>
#import "LKS_InbuiltAttrModificationHandler.h"
#import "LKS_CustomAttrModificationHandler.h"
#import "LKS_AttrModificationPatchHandler.h"
#import "LKS_HierarchyDetailsHandler.h"
#import "LookinServerDefines.h"
#import "LookinHierarchyInfo+LookinServer.h"
#import "UIImage+LookinServer.h"
#import "NSValue+Lookin.h"
#import <objc/runtime.h>

@interface LKS_RequestHandler ()

@property(nonatomic, weak, readwrite) Lookin_PTChannel *boundChannel;
@property(nonatomic, strong) NSMutableSet<LKS_HierarchyDetailsHandler *> *activeDetailHandlers;
@property(nonatomic, strong) NSSet<NSNumber *> *validRequestTypes;

@end

@implementation LKS_RequestHandler

- (instancetype)init {
    return [self initWithChannel:nil];
}

- (instancetype)initWithChannel:(Lookin_PTChannel *)channel {
    if (self = [super init]) {
        _boundChannel = channel;
        _validRequestTypes = [NSSet setWithArray:@[
            @(LookinRequestTypePing),
            @(LookinRequestTypeApp),
            @(LookinRequestTypeHierarchy),
            @(LookinRequestTypeHierarchyDetails),
            @(LookinRequestTypeInbuiltAttrModification),
            @(LookinRequestTypeCustomAttrModification),
            @(LookinRequestTypeAttrModificationPatch),
            @(LookinRequestTypeFetchObject),
            @(LookinRequestTypeAllAttrGroups),
            @(LookinRequestTypeAllSelectorNames),
            @(LookinRequestTypeInvokeMethod),
            @(LookinRequestTypeFetchImageViewImage),
            @(LookinRequestTypeModifyRecognizerEnable),
            @(LookinRequestTypeIntrospect),
            @(LookinRequestTypeSwiftUIDebugData),
            @(LookinPush_CanceHierarchyDetails),
        ]];
        _activeDetailHandlers = [NSMutableSet set];
    }
    return self;
}

- (BOOL)canHandleRequestType:(uint32_t)requestType {
    return [self.validRequestTypes containsObject:@(requestType)];
}

/// Sends an attachment to *this handler's* bound channel only. Multiple
/// clients may be connected concurrently, so we never go through the
/// connection manager singleton — that would race on which channel
/// receives the response.
///
/// If the channel has been torn down between request and response (the
/// client disconnected mid-flight), the send is silently dropped.
- (void)_sendAttachment:(LookinConnectionResponseAttachment *)attachment
            requestType:(uint32_t)requestType
                    tag:(uint32_t)tag {
    Lookin_PTChannel *channel = self.boundChannel;
    if (!channel) {
        return;
    }
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:attachment];
    dispatch_data_t payload = [archived createReferencingDispatchData];
    [channel sendFrameOfType:requestType tag:tag withPayload:payload callback:^(NSError *error) {
        // Errors here mean the peer went away mid-write; nothing useful
        // to do other than let the channel's own teardown clean up.
    }];
}

- (void)_respondWithData:(id)data requestType:(uint32_t)requestType tag:(uint32_t)tag {
    LookinConnectionResponseAttachment *attachment = [LookinConnectionResponseAttachment new];
    attachment.data = data;
    [self _sendAttachment:attachment requestType:requestType tag:tag];
}

- (void)_respondWithError:(NSError *)error requestType:(uint32_t)requestType tag:(uint32_t)tag {
    LookinConnectionResponseAttachment *attachment = [LookinConnectionResponseAttachment new];
    attachment.error = error ?: LookinErr_Inner;
    [self _sendAttachment:attachment requestType:requestType tag:tag];
}

- (void)handleRequestType:(uint32_t)requestType tag:(uint32_t)tag object:(id)object {
    if (requestType == LookinRequestTypePing) {
        LookinConnectionResponseAttachment *attachment = [LookinConnectionResponseAttachment new];
#if TARGET_OS_OSX
        attachment.appIsInBackground = NO;
#else
        attachment.appIsInBackground = ![LKS_ConnectionManager sharedInstance].applicationIsActive;
#endif
        [self _sendAttachment:attachment requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinRequestTypeApp) {
        NSDictionary *params = [object isKindOfClass:[NSDictionary class]] ? object : @{};
        BOOL needImages = [params[@"needImages"] boolValue];
        NSArray<NSNumber *> *localIdentifiers = [params[@"local"] isKindOfClass:[NSArray class]] ? params[@"local"] : @[];
        [self _respondWithData:[LookinAppInfo currentInfoWithScreenshot:needImages icon:needImages localIdentifiers:localIdentifiers] requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinRequestTypeHierarchy) {
        NSString *clientVersion = [object isKindOfClass:[NSDictionary class]] ? object[@"clientVersion"] : nil;
        [self _respondWithData:[LookinHierarchyInfo staticInfoWithLookinVersion:clientVersion] requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinRequestTypeHierarchyDetails) {
        NSArray<LookinStaticAsyncUpdateTasksPackage *> *packages = [object isKindOfClass:[NSArray class]] ? object : @[];
        NSUInteger responsesDataTotalCount = 0;
        for (LookinStaticAsyncUpdateTasksPackage *package in packages) {
            responsesDataTotalCount += package.tasks.count;
        }
        // Bind the detail handler to *this* connection's channel so that
        // a different client disconnecting cannot cancel our paginated
        // stream. See LKS_HierarchyDetailsHandler's notification filter.
        LKS_HierarchyDetailsHandler *handler =
            [[LKS_HierarchyDetailsHandler alloc] initWithChannel:self.boundChannel];
        [self.activeDetailHandlers addObject:handler];
        __weak typeof(self) weakSelf = self;
        [handler startWithPackages:packages block:^(NSArray<LookinDisplayItemDetail *> *details) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { return; }
            LookinConnectionResponseAttachment *attachment = [LookinConnectionResponseAttachment new];
            attachment.data = details;
            attachment.dataTotalCount = responsesDataTotalCount;
            attachment.currentDataCount = details.count;
            [strongSelf _sendAttachment:attachment requestType:requestType tag:tag];
        } finishedBlock:^{
            [self.activeDetailHandlers removeObject:handler];
        }];
        return;
    }

    if (requestType == LookinRequestTypeInbuiltAttrModification) {
        [LKS_InbuiltAttrModificationHandler handleModification:object completion:^(LookinDisplayItemDetail *data, NSError *error) {
            if (error) {
                [self _respondWithError:error requestType:requestType tag:tag];
            } else {
                [self _respondWithData:data requestType:requestType tag:tag];
            }
        }];
        return;
    }

    if (requestType == LookinRequestTypeAttrModificationPatch) {
        [LKS_InbuiltAttrModificationHandler handlePatchWithTasks:[object isKindOfClass:[NSArray class]] ? object : @[] block:^(LookinDisplayItemDetail *data) {
            [self _respondWithData:data requestType:requestType tag:tag];
        }];
        return;
    }

    if (requestType == LookinRequestTypeFetchObject) {
        NSObject *resolvedObject = [NSObject lks_objectWithOid:[(NSNumber *)object unsignedLongValue]];
        [self _respondWithData:[LookinObject instanceWithObject:resolvedObject] requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinRequestTypeAllAttrGroups) {
        NSObject *resolvedObject = [NSObject lks_objectWithOid:[(NSNumber *)object unsignedLongValue]];
        NSArray<LookinAttributesGroup *> *groups = nil;
        if ([resolvedObject isKindOfClass:[CALayer class]]) {
            groups = [LKS_AttrGroupsMaker attrGroupsForLayer:(CALayer *)resolvedObject];
        }
#if TARGET_OS_OSX
        else if ([resolvedObject isKindOfClass:[NSView class]]) {
            groups = [LKS_AttrGroupsMaker attrGroupsForView:(NSView *)resolvedObject];
        } else if ([resolvedObject isKindOfClass:[NSWindow class]]) {
            groups = [LKS_AttrGroupsMaker attrGroupsForWindow:(NSWindow *)resolvedObject];
        }
#endif
#if TARGET_OS_IPHONE
        else if ([resolvedObject isKindOfClass:[UIView class]]) {
            // Fall back to the view's layer; the layer attribute set is what
            // historically backed UIView attribute browsing on iOS/tvOS/visionOS.
            groups = [LKS_AttrGroupsMaker attrGroupsForLayer:((UIView *)resolvedObject).layer];
        } else if (@available(iOS 13.0, tvOS 13.0, *)) {
            if ([resolvedObject isKindOfClass:[UIWindowScene class]]) {
                groups = [LKS_AttrGroupsMaker attrGroupsForWindowScene:(UIWindowScene *)resolvedObject];
            }
        }
#endif
        if (!groups) {
            [self _respondWithError:LookinErr_ObjNotFound requestType:requestType tag:tag];
            return;
        }
        [self _respondWithData:groups requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinRequestTypeIntrospect) {
        unsigned long oid = 0;
        if ([object isKindOfClass:[NSNumber class]]) {
            oid = [(NSNumber *)object unsignedLongValue];
        } else if ([object isKindOfClass:[NSDictionary class]]) {
            oid = [[(NSDictionary *)object objectForKey:@"oid"] unsignedLongValue];
        }
        NSObject *resolvedObject = [NSObject lks_objectWithOid:oid];
        NSDictionary *info = [LKS_IntrospectionHandler introspectObject:resolvedObject];
        [self _respondWithData:info requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinRequestTypeSwiftUIDebugData) {
        // SwiftUI exposes two undocumented selectors on every NSHostingView /
        // _UIHostingView subclass that the Xcode View Debugger consumes. They
        // are stable public-ish ObjC entry points and return structured JSON /
        // NSArray that already contain font / colour / text attributes for
        // every Text/Image in the hosted SwiftUI tree.
        //
        // Both selectors are exposed via libViewDebuggerSupport.dylib (auto-
        // injected by Xcode when launching with `Cmd+R`, or by the host when
        // the env var `SWIFTUI_VIEW_DEBUG=287` is set). The selectors exist on
        // _UIHostingView (iOS / tvOS / visionOS) and NSHostingView (macOS)
        // alike; the implementation differs only in whether the resulting
        // NSData payload is large enough to trip the macOS 26 NSKeyedUnarchiver
        // bug — see the inner `#if TARGET_OS_OSX` for the spool-to-file
        // workaround that only macOS 26 hosts need.
        unsigned long oid = [(NSNumber *)object unsignedLongValue];
        NSObject *resolvedObject = [NSObject lks_objectWithOid:oid];
        if (!resolvedObject) {
            [self _respondWithError:LookinErr_ObjNotFound requestType:requestType tag:tag];
            return;
        }

        NSMutableDictionary *response = [NSMutableDictionary dictionary];
        response[@"className"] = NSStringFromClass([resolvedObject class]) ?: @"";

        SEL makeViewDebugDataSel = @selector(makeViewDebugData);
        SEL accessibilityDebugSel = @selector(_accessibilitySwiftUIDebugData);

        // Anything we put on the wire is sent through NSKeyedArchiver. The
        // accessibility selector commonly returns NSArray<__SwiftValue *>
        // (Swift structs boxed for ObjC), and __SwiftValue does NOT conform
        // to NSCoding, so naively returning the array crashes the host with
        // -[__SwiftValue encodeWithCoder:]: unrecognized selector. We convert
        // anything non-archivable to its -description string so the wire
        // payload stays safe; JSON-parsed payloads from makeViewDebugData are
        // already pure NSArray/NSDictionary/NSString/NSNumber and pass through
        // verbatim.
        //
        // Also caps recursion depth: SwiftUI's accessibilityDebugData routinely
        // nests 500+ levels deep, well beyond NSPropertyListSerialization's
        // (and NSJSONSerialization's) ~512-level recursion limit. The cap
        // below is chosen to (a) stay under NSJSONSerialization's internal
        // stack guard (~512 on macOS 26) and (b) be high enough to admit the
        // real SwiftUI graphs we see in practice — NavigationSplit-hosted
        // apps on macOS 26 need ~250 levels to reach the per-column body,
        // because every modifier (ModifiedContent, _ViewModifier_Content,
        // _PreferenceWritingModifier, ...) counts as one level *and* each
        // node's `properties`/`attribute`/`subattributes` chain contributes
        // a further ~3x on top of the visible tree depth.
        //
        // 400 gives ~2x headroom over the observed depth (~220 for our
        // worst case) while staying comfortably under JSON's 512 limit.
        // Anything deeper is summarised as "<truncated>" to keep the payload
        // serialisable.
        __block id (^sanitizeDepth)(id, int) = nil;
        sanitizeDepth = ^id(id obj, int depth) {
            if (depth > 400) return @"<truncated>";
            if (!obj || [obj isKindOfClass:[NSNull class]]) return obj;
            if ([obj isKindOfClass:[NSString class]] ||
                [obj isKindOfClass:[NSNumber class]]) return obj;
            if ([obj isKindOfClass:[NSArray class]]) {
                NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[obj count]];
                for (id sub in (NSArray *)obj) {
                    id s = sanitizeDepth(sub, depth + 1);
                    [arr addObject:s ?: [NSNull null]];
                }
                return arr;
            }
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                    NSString *k = [key isKindOfClass:[NSString class]] ? key : [key description];
                    if (k) out[k] = sanitizeDepth(value, depth + 1) ?: [NSNull null];
                }];
                return out;
            }
            // Fallback: any non-plist class (including __SwiftValue) becomes
            // its description string so NSKeyedArchiver can encode it.
            @try {
                return [obj description] ?: @"";
            } @catch (__unused id _) {
                return @"<undescribable>";
            }
        };
        // Convenience: top-level entry that starts at depth 0.
        id (^sanitize)(id) = ^id(id obj) { return sanitizeDepth(obj, 0); };

        void (^collect)(void) = ^{
            if ([resolvedObject respondsToSelector:makeViewDebugDataSel]) {
                id raw = nil;
                @try {
                    raw = ((id (*)(id, SEL))objc_msgSend)(resolvedObject, makeViewDebugDataSel);
                } @catch (__unused id _) {}
                if ([raw isKindOfClass:[NSData class]]) {
                    NSData *rawData = (NSData *)raw;
                    NSUInteger len = rawData.length;
                    // Large NSData payloads (SwiftUIDebugData's 50 MB JSON for
                    // non-trivial hosting views) trip a macOS 26
                    // NSKeyedUnarchiver bug on the client where the secure-
                    // coding warning generator self-recurses on +[NSObject
                    // description] and overflows the stack guard with SIGBUS
                    // while decoding nested NSDictionary trees.
                    //
                    // Workaround: spool the payload unconditionally on macOS
                    // to a temp file under NSTemporaryDirectory() and put just
                    // the path in the response. The client maps it back into
                    // the viewDebugData field after decoding the (now small)
                    // attachment. iOS / tvOS / visionOS keep the inline
                    // payload — they don't hit the bug and they aren't
                    // necessarily on the same filesystem as the client.
#if TARGET_OS_OSX
                    NSString *fileName = [NSString stringWithFormat:
                                          @"lks-swiftui-%lu-%@.json",
                                          oid, [[NSUUID UUID] UUIDString]];
                    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
                    NSError *writeErr = nil;
                    BOOL ok = [rawData writeToFile:path
                                           options:NSDataWritingAtomic
                                             error:&writeErr];
                    if (ok) {
                        response[@"viewDebugDataFormat"] = @"file";
                        response[@"viewDebugDataFilePath"] = path;
                        response[@"viewDebugDataLength"] = @(len);
                    } else {
                        // Spool failed (disk full, sandbox trouble, ...).
                        // Fall back to inline: the client may SIGBUS on the
                        // macOS 26 bug, but silently truncating would be
                        // worse — the user needs to see the error surface.
                        response[@"viewDebugData"] = rawData;
                        response[@"viewDebugDataFormat"] = @"raw";
                        response[@"viewDebugDataLength"] = @(len);
                    }
#else
                    response[@"viewDebugData"] = rawData;
                    response[@"viewDebugDataFormat"] = @"raw";
                    response[@"viewDebugDataLength"] = @(len);
#endif
                } else if (raw) {
                    response[@"viewDebugData"] = sanitize(raw);
                    response[@"viewDebugDataFormat"] = @"sanitized";
                }
            }

            if ([resolvedObject respondsToSelector:accessibilityDebugSel]) {
                id raw = nil;
                @try {
                    raw = ((id (*)(id, SEL))objc_msgSend)(resolvedObject, accessibilityDebugSel);
                } @catch (__unused id _) {}
                if (raw) {
                    id sanitized = sanitize(raw);
                    // The sanitized AX tree is structurally identical to
                    // SwiftUI's view-graph dump and routinely contains
                    // 30 000+ nested NSDictionary nodes. NSKeyedArchiver
                    // round-tripping that on macOS 26 trips the
                    // _warnAboutNSObjectInAllowedClassesWithException
                    // recursion bug regardless of byte size, so always spill
                    // the AX payload to a temp file no matter the encoding.
#if TARGET_OS_OSX
                    NSData *axBytes = nil;
                    NSString *axEncoding = nil;
                    // Prefer JSON because the client side can decode it
                    // without going through NSKeyedUnarchiver (which is what
                    // we're trying to avoid). When sanitize left non-JSON
                    // remnants, fall back to a binary plist — it accepts
                    // any NSObject that conforms to NSCoding and similarly
                    // doesn't pin the unarchiver allowed-classes set.
                    if ([NSJSONSerialization isValidJSONObject:sanitized]) {
                        axBytes = [NSJSONSerialization dataWithJSONObject:sanitized
                                                                  options:0
                                                                    error:NULL];
                        axEncoding = @"json";
                    }
                    if (!axBytes) {
                        @try {
                            axBytes = [NSPropertyListSerialization
                                       dataWithPropertyList:sanitized
                                                     format:NSPropertyListBinaryFormat_v1_0
                                                    options:0
                                                      error:NULL];
                            axEncoding = @"plist";
                        } @catch (__unused id _) {}
                    }
                    if (axBytes) {
                        NSString *fileName = [NSString stringWithFormat:
                                              @"lks-swiftui-ax-%lu-%@.bin",
                                              oid, [[NSUUID UUID] UUIDString]];
                        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
                        if ([axBytes writeToFile:path
                                         options:NSDataWritingAtomic
                                           error:NULL]) {
                            response[@"accessibilityDebugDataFormat"] = @"file";
                            response[@"accessibilityDebugDataFilePath"] = path;
                            response[@"accessibilityDebugDataEncoding"] = axEncoding;
                            response[@"accessibilityDebugDataLength"] = @(axBytes.length);
                        }
                        // If write fails, drop the field rather than fall back
                        // to inline (which would re-trigger the macOS 26 bug).
                    }
                    // If neither encoding worked at all, drop the field —
                    // sending the raw nested dict inline would crash the client.
#else
                    response[@"accessibilityDebugData"] = sanitized;
#endif
                }
            }
        };

        if ([NSThread isMainThread]) {
            collect();
        } else {
            dispatch_sync(dispatch_get_main_queue(), collect);
        }

        [self _respondWithData:response requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinRequestTypeAllSelectorNames) {
        NSDictionary *params = [object isKindOfClass:[NSDictionary class]] ? object : nil;
        Class targetClass = NSClassFromString(params[@"className"]);
        if (!targetClass) {
            [self _respondWithError:LookinErr_Inner requestType:requestType tag:tag];
            return;
        }
        BOOL hasArg = [params[@"hasArg"] boolValue];
        NSMutableArray<NSString *> *selectors = [NSMutableArray array];
        Class currentClass = targetClass;
        while (currentClass) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(currentClass, &methodCount);
            for (unsigned int i = 0; i < methodCount; i++) {
                NSString *selName = NSStringFromSelector(method_getName(methods[i]));
                if (!hasArg && [selName containsString:@":"]) {
                    continue;
                }
                if (selName.length && ![selectors containsObject:selName]) {
                    [selectors addObject:selName];
                }
            }
            free(methods);
            currentClass = currentClass.superclass;
        }
        [self _respondWithData:selectors requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinRequestTypeInvokeMethod) {
        NSDictionary *params = [object isKindOfClass:[NSDictionary class]] ? object : nil;
        NSObject *targetObject = [NSObject lks_objectWithOid:[params[@"oid"] unsignedLongValue]];
        SEL selector = NSSelectorFromString(params[@"text"]);
        if (!targetObject || !selector || ![targetObject respondsToSelector:selector]) {
            [self _respondWithError:LookinErr_ObjNotFound requestType:requestType tag:tag];
            return;
        }
        NSMethodSignature *signature = [targetObject methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments > 2) {
            [self _respondWithError:LookinErr_Inner requestType:requestType tag:tag];
            return;
        }
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = targetObject;
        invocation.selector = selector;
        [invocation invoke];

        NSMutableDictionary *response = [NSMutableDictionary dictionary];
        if (strcmp(signature.methodReturnType, @encode(void)) == 0) {
            response[@"description"] = LookinStringFlag_VoidReturn;
        } else if (signature.methodReturnLength == sizeof(id)) {
            __unsafe_unretained id returnValue = nil;
            [invocation getReturnValue:&returnValue];
            if (returnValue) {
                response[@"description"] = [returnValue description] ?: @"";
                if ([returnValue isKindOfClass:[NSObject class]]) {
                    response[@"object"] = [LookinObject instanceWithObject:returnValue];
                }
            }
        } else {
            response[@"description"] = @"Method invoked.";
        }
        [self _respondWithData:response requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinRequestTypeFetchImageViewImage) {
#if TARGET_OS_OSX
        NSImageView *imageView = (NSImageView *)[NSObject lks_objectWithOid:[(NSNumber *)object unsignedLongValue]];
        if (![imageView isKindOfClass:[NSImageView class]] || !imageView.image) {
            [self _respondWithError:LookinErr_ObjNotFound requestType:requestType tag:tag];
            return;
        }
        [self _respondWithData:imageView.image.lookin_data requestType:requestType tag:tag];
#else
        UIImageView *imageView = (UIImageView *)[NSObject lks_objectWithOid:[(NSNumber *)object unsignedLongValue]];
        if (![imageView isKindOfClass:[UIImageView class]] || !imageView.image) {
            [self _respondWithError:LookinErr_ObjNotFound requestType:requestType tag:tag];
            return;
        }
        [self _respondWithData:[imageView.image lookin_data] requestType:requestType tag:tag];
#endif
        return;
    }

    if (requestType == LookinRequestTypeModifyRecognizerEnable) {
        [self _respondWithError:LookinErr_Inner requestType:requestType tag:tag];
        return;
    }

    if (requestType == LookinPush_CanceHierarchyDetails) {
        for (LKS_HierarchyDetailsHandler *handler in self.activeDetailHandlers.copy) {
            [handler cancel];
        }
        [self.activeDetailHandlers removeAllObjects];
        return;
    }

    [self _respondWithError:LookinErr_Inner requestType:requestType tag:tag];
}

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
