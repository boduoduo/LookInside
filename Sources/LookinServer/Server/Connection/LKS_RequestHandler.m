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

@property(nonatomic, strong) NSMutableSet<LKS_HierarchyDetailsHandler *> *activeDetailHandlers;
@property(nonatomic, strong) NSSet<NSNumber *> *validRequestTypes;

@end

@implementation LKS_RequestHandler

- (instancetype)init {
    if (self = [super init]) {
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

- (void)_respondWithData:(id)data requestType:(uint32_t)requestType tag:(uint32_t)tag {
    LookinConnectionResponseAttachment *attachment = [LookinConnectionResponseAttachment new];
    attachment.data = data;
    [[LKS_ConnectionManager sharedInstance] respond:attachment requestType:requestType tag:tag];
}

- (void)_respondWithError:(NSError *)error requestType:(uint32_t)requestType tag:(uint32_t)tag {
    LookinConnectionResponseAttachment *attachment = [LookinConnectionResponseAttachment new];
    attachment.error = error ?: LookinErr_Inner;
    [[LKS_ConnectionManager sharedInstance] respond:attachment requestType:requestType tag:tag];
}

- (void)handleRequestType:(uint32_t)requestType tag:(uint32_t)tag object:(id)object {
    if (requestType == LookinRequestTypePing) {
        LookinConnectionResponseAttachment *attachment = [LookinConnectionResponseAttachment new];
#if TARGET_OS_OSX
        attachment.appIsInBackground = NO;
#else
        attachment.appIsInBackground = ![LKS_ConnectionManager sharedInstance].applicationIsActive;
#endif
        [[LKS_ConnectionManager sharedInstance] respond:attachment requestType:requestType tag:tag];
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
        LKS_HierarchyDetailsHandler *handler = [LKS_HierarchyDetailsHandler new];
        [self.activeDetailHandlers addObject:handler];
        [handler startWithPackages:packages block:^(NSArray<LookinDisplayItemDetail *> *details) {
            LookinConnectionResponseAttachment *attachment = [LookinConnectionResponseAttachment new];
            attachment.data = details;
            attachment.dataTotalCount = responsesDataTotalCount;
            attachment.currentDataCount = details.count;
            [[LKS_ConnectionManager sharedInstance] respond:attachment requestType:requestType tag:tag];
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
#if TARGET_OS_OSX
        unsigned long oid = [(NSNumber *)object unsignedLongValue];
        NSObject *resolvedObject = [NSObject lks_objectWithOid:oid];
        if (!resolvedObject) {
            [self _respondWithError:LookinErr_ObjNotFound requestType:requestType tag:tag];
            return;
        }

        NSMutableDictionary *response = [NSMutableDictionary dictionary];
        response[@"className"] = NSStringFromClass([resolvedObject class]) ?: @"";

        // SwiftUI exposes two undocumented selectors on every NSHostingView
        // subclass that the Xcode View Debugger consumes. They are stable
        // public-ish ObjC entry points and return structured JSON / NSArray
        // that already contain font / colour / text attributes for every
        // Text/Image in the hosted SwiftUI tree.
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
        // (and NSJSONSerialization's) ~512-level recursion limit. Anything
        // past depth 60 is summarised as "<truncated>" so the result is
        // serialisable by either format.
        __block id (^sanitizeDepth)(id, int) = nil;
        sanitizeDepth = ^id(id obj, int depth) {
            if (depth > 60) return @"<truncated>";
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
                    // Large NSData payloads (notably SwiftUIDebugData's 50 MB
                    // JSON for non-trivial hosting views) trip a macOS 26
                    // NSKeyedUnarchiver bug on the client where the secure-
                    // coding warning generator self-recurses on +[NSObject
                    // description] and overflows the stack guard with SIGBUS
                    // while decoding nested NSDictionary trees.
                    //
                    // Workaround: spool any payload above the threshold to a
                    // temp file under NSTemporaryDirectory() and put just the
                    // path in the response. The client maps it back into the
                    // viewDebugData field after decoding the (now small)
                    // attachment. macOS server + macOS client are always on
                    // the same machine so a shared filesystem path is safe;
                    // iOS / tvOS / visionOS targets keep the inline payload.
                    static const NSUInteger spillThreshold = 0; // always spill on macOS
#if TARGET_OS_OSX
                    if (len >= spillThreshold) {
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
                            // Don't include the bytes themselves — that is the
                            // entire point of the spill.
                        } else {
                            // Fall back to inline if the spool failed; the
                            // client may still hit the macOS 26 bug, but
                            // truncating silently would be worse.
                            response[@"viewDebugData"] = rawData;
                            response[@"viewDebugDataFormat"] = @"raw";
                            response[@"viewDebugDataLength"] = @(len);
                        }
                    } else {
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
#else
        [self _respondWithError:LookinErr_Inner requestType:requestType tag:tag];
        return;
#endif
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
