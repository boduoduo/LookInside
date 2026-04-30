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
#if TARGET_OS_OSX
#import "LKS_TextDrawHook.h"
#endif
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
            @(LookinRequestTypeTextSnapshot),
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

    if (requestType == LookinRequestTypeTextSnapshot) {
#if TARGET_OS_OSX
        unsigned long oid = [(NSNumber *)object unsignedLongValue];
        NSObject *resolvedObject = [NSObject lks_objectWithOid:oid];
        if (![resolvedObject isKindOfClass:[CALayer class]]) {
            [self _respondWithError:LookinErr_ObjNotFound requestType:requestType tag:tag];
            return;
        }
        CALayer *layer = (CALayer *)resolvedObject;
        CGFloat w = MAX(layer.bounds.size.width, 1);
        CGFloat h = MAX(layer.bounds.size.height, 1);

        // We render into a throw-away offscreen bitmap so the host's actual
        // CALayer presentation isn't disturbed; the hook only records calls
        // made into *this* context (in fact, into any context — the TLS
        // capture flag scopes it correctly regardless).
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)w, (size_t)h, 8, 0, cs,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(cs);

        NSArray<LKS_TextDrawRecord *> *records =
            [LKS_TextDrawHook snapshotWithBlock:^{
                if (!ctx) return;
                // Self-probe: prove the hook is wired.
                CTFontRef probeFont = CTFontCreateWithName(CFSTR("Helvetica"), 12, NULL);
                if (probeFont) {
                    UniChar probeChars[] = { 'L', 'K', 'S' };
                    CGGlyph probeGlyphs[3] = {0};
                    CTFontGetGlyphsForCharacters(probeFont, probeChars, probeGlyphs, 3);
                    CGPoint probePts[3] = { {0,0}, {6,0}, {12,0} };
                    CTFontDrawGlyphs(probeFont, probeGlyphs, probePts, 3, ctx);
                    CFRelease(probeFont);
                }

                // SwiftUI _CGDrawingLayer caches its rasterised text in
                // `layer.contents` and skips its draw closure on subsequent
                // displays. Wipe contents + force a fresh display to get the
                // closure to re-execute. This is safe because dyld will
                // re-render the layer in the next CA commit cycle anyway.
                id savedContents = layer.contents;
                layer.contents = nil;
                [layer setNeedsDisplay];
                if ([layer respondsToSelector:@selector(displayIfNeeded)]) {
                    [layer displayIfNeeded];
                } else {
                    [layer display];
                }
                [layer drawInContext:ctx];
                [layer renderInContext:ctx];
                if (layer.contents == nil) layer.contents = savedContents;
            }];

        if (ctx) CGContextRelease(ctx);

        NSMutableArray *out = [NSMutableArray array];
        for (LKS_TextDrawRecord *r in records) {
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            if (r.fontName)       d[@"fontName"] = r.fontName;
            if (r.postScriptName) d[@"postScriptName"] = r.postScriptName;
            d[@"fontSize"] = @(r.fontSize);
            if (r.fontTraits.length) d[@"fontTraits"] = r.fontTraits;
            if (r.text)           d[@"text"] = r.text;
            if (r.glyphs.count)   d[@"glyphCount"] = @(r.glyphs.count);
            if (r.fillRGBA.count) d[@"fillRGBA"] = r.fillRGBA;
            [out addObject:d];
        }
        NSDictionary *response = @{
            @"hooksInstalled": @([LKS_TextDrawHook installHooks]),
            @"recordCount": @(out.count),
            @"records": out,
        };
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
