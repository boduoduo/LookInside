#if defined(SHOULD_COMPILE_LOOKIN_SERVER)
//
//  LKS_IntrospectionHandler.m
//  LookinServer
//

#import "LKS_IntrospectionHandler.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreGraphics/CoreGraphics.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

#pragma mark - Helpers

static NSString *LKS_DescribeColor(id colorOrNil) {
    if (!colorOrNil) return nil;
#if TARGET_OS_OSX
    if (![colorOrNil isKindOfClass:[NSColor class]]) return nil;
    NSColor *color = colorOrNil;
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: color;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    @try { [rgb getRed:&r green:&g blue:&b alpha:&a]; } @catch (__unused id _) { return [color description]; }
#else
    if (![colorOrNil isKindOfClass:[UIColor class]]) return nil;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![colorOrNil getRed:&r green:&g blue:&b alpha:&a]) {
        return [colorOrNil description];
    }
#endif
    return [NSString stringWithFormat:@"rgba(%.3f, %.3f, %.3f, %.3f)", r, g, b, a];
}

static NSString *LKS_DescribeFont(id fontOrNil) {
    if (!fontOrNil) return nil;
#if TARGET_OS_OSX
    if (![fontOrNil isKindOfClass:[NSFont class]]) return nil;
    NSFont *font = fontOrNil;
#else
    if (![fontOrNil isKindOfClass:[UIFont class]]) return nil;
    UIFont *font = fontOrNil;
#endif
    return [NSString stringWithFormat:@"%@ %.2fpt", font.fontName, (double)font.pointSize];
}

/// Best-effort short description for arbitrary ivar/property values.
/// Returns nil when value is nil so we can omit the key.
static NSString *LKS_ShortDescription(id value) {
    if (!value) return nil;
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    if ([value isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString *)value string];

    NSString *colorDesc = LKS_DescribeColor(value);
    if (colorDesc) return colorDesc;

    NSString *fontDesc = LKS_DescribeFont(value);
    if (fontDesc) return fontDesc;

    NSString *desc = nil;
    @try {
        desc = [value description];
    } @catch (__unused id _) {
        desc = [NSString stringWithFormat:@"<%@: %p>", NSStringFromClass([value class]), value];
    }
    if (desc.length > 512) {
        desc = [[desc substringToIndex:512] stringByAppendingString:@"…"];
    }
    return desc ?: @"";
}

/// Decodes a single ivar safely. Only ObjC object ivars are dereferenced.
/// Primitive ivars return their type encoding so the caller still has context.
static NSDictionary *LKS_DescribeIvar(id object, Ivar ivar) {
    const char *cName = ivar_getName(ivar);
    const char *cType = ivar_getTypeEncoding(ivar);
    NSString *name = cName ? @(cName) : @"?";
    NSString *type = cType ? @(cType) : @"?";

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"name"] = name;
    out[@"type"] = type;

    if (cType && cType[0] == '@') {
        id value = nil;
        @try {
            value = object_getIvar(object, ivar);
        } @catch (__unused id _) {
            out[@"value"] = @"<unreadable>";
            return out;
        }
        if (value) {
            out[@"objcClass"] = NSStringFromClass([value class]);
            NSString *desc = LKS_ShortDescription(value);
            if (desc) out[@"value"] = desc;
        }
    }
    return out;
}

#if TARGET_OS_OSX
/// Read a couple of accessibility attributes off any NSView. We use the modern
/// NSAccessibility protocol getters (accessibilityRole / accessibilityValue /
/// accessibilityLabel etc.) introduced in macOS 10.10 — these are the public
/// API that SwiftUI's bridged NSViews implement, so we can pull text content,
/// roles, and enabled/focused state without touching deprecated APIs.
static NSDictionary *LKS_AccessibilityInfo(id object) {
    if (![object conformsToProtocol:@protocol(NSAccessibility)]) {
        return nil;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    // Pair each accessor we care about with its label. We prefer modern
    // selectors only; @try wraps every call because some bridged views throw
    // when an attribute isn't applicable to their role.
    SEL selectors[] = {
        @selector(accessibilityRole),
        @selector(accessibilityRoleDescription),
        @selector(accessibilitySubrole),
        @selector(accessibilityValue),
        @selector(accessibilityValueDescription),
        @selector(accessibilityLabel),
        @selector(accessibilityTitle),
        @selector(accessibilityHelp),
        @selector(accessibilityPlaceholderValue),
        @selector(accessibilityIdentifier),
    };
    NSString *labels[] = {
        @"role",
        @"roleDescription",
        @"subrole",
        @"value",
        @"valueDescription",
        @"label",
        @"title",
        @"help",
        @"placeholder",
        @"identifier",
    };
    for (size_t i = 0; i < sizeof(selectors)/sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if (![object respondsToSelector:sel]) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)(object, sel);
        } @catch (__unused id _) {
            continue;
        }
        if (!value) continue;
        NSString *short_ = LKS_ShortDescription(value);
        if (short_.length) info[labels[i]] = short_;
    }

    // Boolean state attributes. We special-case these because objc_msgSend
    // returns BOOL (a single byte) which we shouldn't read as id.
    SEL boolSelectors[] = {
        @selector(isAccessibilityEnabled),
        @selector(isAccessibilityFocused),
        @selector(isAccessibilitySelected),
    };
    NSString *boolLabels[] = { @"enabled", @"focused", @"selected" };
    for (size_t i = 0; i < sizeof(boolSelectors)/sizeof(boolSelectors[0]); i++) {
        SEL sel = boolSelectors[i];
        if (![object respondsToSelector:sel]) continue;
        BOOL flag = NO;
        @try {
            flag = ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
        } @catch (__unused id _) {
            continue;
        }
        info[boolLabels[i]] = flag ? @"YES" : @"NO";
    }

    return info.count ? info : nil;
}
#endif

/// AppKit-native font/string/color quick-look. These use only public API
/// (font / textColor / stringValue / attributedStringValue / placeholderString
/// / title) and silently skip any selector the receiver doesn't respond to,
/// so the same helper works for NSTextField, NSTextView, NSButton, NSImageView,
/// etc. without needing per-class overrides.
static NSDictionary *LKS_AppKitQuickLook(id object) {
#if TARGET_OS_OSX
    if (![object isKindOfClass:[NSResponder class]]) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    SEL selectors[] = {
        @selector(stringValue), @selector(attributedStringValue),
        @selector(placeholderString), @selector(placeholderAttributedString),
        @selector(title), @selector(alternateTitle),
        @selector(font), @selector(textColor), @selector(backgroundColor),
        @selector(image), @selector(alternateImage),
    };
    NSString *labels[] = {
        @"stringValue", @"attributedStringValue",
        @"placeholderString", @"placeholderAttributedString",
        @"title", @"alternateTitle",
        @"font", @"textColor", @"backgroundColor",
        @"image", @"alternateImage",
    };
    for (size_t i = 0; i < sizeof(selectors)/sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if (![object respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [object methodSignatureForSelector:sel];
        if (!sig || strcmp(sig.methodReturnType, @encode(id)) != 0) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)(object, sel);
        } @catch (__unused id _) {
            continue;
        }
        if (!value) continue;
        NSString *desc = LKS_ShortDescription(value);
        if (desc.length) out[labels[i]] = desc;
    }
    return out.count ? out : nil;
#else
    return nil;
#endif
}

@implementation LKS_IntrospectionHandler

+ (NSDictionary *)introspectObject:(id)object {
    if (!object) {
        return @{ @"error": @"Object not found for the requested OID." };
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    Class cls = [object class];
    result[@"className"] = NSStringFromClass(cls) ?: @"";
    result[@"address"] = [NSString stringWithFormat:@"%p", object];

    NSMutableArray *superchain = [NSMutableArray array];
    Class walker = class_getSuperclass(cls);
    while (walker) {
        NSString *name = NSStringFromClass(walker);
        if (name) [superchain addObject:name];
        walker = class_getSuperclass(walker);
    }
    result[@"superclasses"] = superchain;

    // Ivars on the leaf class only — superclass ivars rarely give useful
    // SwiftUI insight and the list explodes for NSResponder hierarchies.
    NSMutableArray *ivarsOut = [NSMutableArray array];
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        [ivarsOut addObject:LKS_DescribeIvar(object, ivars[i])];
    }
    free(ivars);
    result[@"ivars"] = ivarsOut;

    NSDictionary *quickLook = LKS_AppKitQuickLook(object);
    if (quickLook) result[@"appkit"] = quickLook;

#if TARGET_OS_OSX
    NSDictionary *ax = LKS_AccessibilityInfo(object);
    if (ax) result[@"accessibility"] = ax;
#endif

    return result;
}

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
