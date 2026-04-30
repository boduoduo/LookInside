#if defined(SHOULD_COMPILE_LOOKIN_SERVER) && TARGET_OS_OSX
//
//  LKS_TextDrawHook.m
//  LookinServer
//

#import "LKS_TextDrawHook.h"
#import "fishhook.h"
#import "fishhook_chained.h"

#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <stdatomic.h>

#pragma mark - Glyph reverse cache

// CTFontDrawGlyphs gives us CGGlyph indices, not Unicode characters. To recover
// the on-screen text we keep a per-font glyph→character cache built lazily by
// scanning the font's character set. The scan is bounded (we only walk BMP +
// SMP planes that are actually inside the font's coverage set) and cached
// keyed by ObjectIdentifier of the CTFontRef so repeated snapshots are cheap.

static NSCache<id, NSDictionary<NSNumber *, NSString *> *> *_glyphCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 64;
    });
    return cache;
}

static NSDictionary<NSNumber *, NSString *> *_buildGlyphMap(CTFontRef font) {
    if (!font) return @{};
    NSString *cacheKey = [NSString stringWithFormat:@"%p|%g",
                          font, (double)CTFontGetSize(font)];
    NSDictionary *cached = [_glyphCache() objectForKey:cacheKey];
    if (cached) return cached;

    CFCharacterSetRef coverage = CTFontCopyCharacterSet(font);
    if (!coverage) return @{};

    NSMutableDictionary<NSNumber *, NSString *> *map = [NSMutableDictionary dictionary];

    // Walk every codepoint in the font's coverage set across BMP+SMP and ask
    // for its glyph. SMP scan is gated behind set membership so emoji-laden
    // fonts don't blow up the cache build cost.
    for (uint32_t cp = 0x0020; cp <= 0x2FFFF; cp++) {
        // Skip surrogate range and the noncharacter range U+FDD0..U+FDEF
        if (cp >= 0xD800 && cp <= 0xDFFF) continue;
        if (cp >= 0xFDD0 && cp <= 0xFDEF) continue;
        if (!CFCharacterSetIsLongCharacterMember(coverage, cp)) continue;

        UniChar units[2];
        CFIndex unitCount;
        if (cp <= 0xFFFF) {
            units[0] = (UniChar)cp;
            unitCount = 1;
        } else {
            uint32_t v = cp - 0x10000;
            units[0] = (UniChar)(0xD800 + (v >> 10));
            units[1] = (UniChar)(0xDC00 + (v & 0x3FF));
            unitCount = 2;
        }
        CGGlyph glyphs[2] = {0, 0};
        if (!CTFontGetGlyphsForCharacters(font, units, glyphs, unitCount)) continue;
        if (glyphs[0] == 0) continue;

        NSNumber *key = @(glyphs[0]);
        if (map[key]) continue; // first character that maps wins

        NSString *str = [[NSString alloc] initWithCharacters:units length:(NSUInteger)unitCount];
        if (str) map[key] = str;

        if (map.count >= 8192) break; // bound the cache size
    }
    CFRelease(coverage);

    [_glyphCache() setObject:map forKey:cacheKey];
    return map;
}

#pragma mark - Recording state

// Per-thread capture flag. Held in TLS so the hooks become no-ops outside an
// active snapshot pass — we never want to incur per-glyph cost during the
// host app's real render loop.
static pthread_key_t _captureKey;
static dispatch_once_t _captureOnce;
static void _ensureCaptureKey(void) {
    dispatch_once(&_captureOnce, ^{
        pthread_key_create(&_captureKey, NULL);
    });
}

typedef struct {
    NSMutableArray<LKS_TextDrawRecord *> *records; // strong via __bridge_retained
    NSArray<NSNumber *> *lastFillRGBA;             // strong via __bridge_retained
} CaptureCtx;

static CaptureCtx *_currentCtx(void) {
    _ensureCaptureKey();
    return (CaptureCtx *)pthread_getspecific(_captureKey);
}

#pragma mark - Hook trampolines

static void (*orig_CTFontDrawGlyphs)(CTFontRef, const CGGlyph *, const CGPoint *, size_t, CGContextRef);
static void (*orig_CGContextSetFillColorWithColor)(CGContextRef, CGColorRef);
static void (*orig_CGContextSetRGBFillColor)(CGContextRef, CGFloat, CGFloat, CGFloat, CGFloat);
static void (*orig_CTLineDraw)(CTLineRef, CGContextRef);
static void (*orig_CTFrameDraw)(CTFrameRef, CGContextRef);
static void (*orig_CTRunDraw)(CTRunRef, CGContextRef, CFRange);

// SwiftUI on macOS 14+ renders text through these CT entry points instead of
// the public CTFontDrawGlyphs / CTLineDraw paths. They share the same
// (font, glyphs, positions, count, ctx) signature for the most part, so we
// can capture them with the same trampoline shape as CTFontDrawGlyphs.
typedef void (*CTFontDrawGlyphsAtPositions_t)(CTFontRef, const CGGlyph *, const CGPoint *, size_t, CGContextRef);
typedef void (*CTFontDrawGlyphsWithAdvances_t)(CTFontRef, const CGGlyph *, const CGSize *, size_t, CGContextRef);
typedef void (*CTRunDrawWithAttributeOverrides_t)(CTRunRef, CGContextRef, CFRange, CFDictionaryRef);
typedef void (*CTLineDrawWithAttributeOverrides_t)(CTLineRef, CGContextRef, CFDictionaryRef);
static CTFontDrawGlyphsAtPositions_t orig_CTFontDrawGlyphsAtPositions;
static CTFontDrawGlyphsWithAdvances_t orig_CTFontDrawGlyphsWithAdvances;
static CTRunDrawWithAttributeOverrides_t orig_CTRunDrawWithAttributeOverrides;
static CTLineDrawWithAttributeOverrides_t orig_CTLineDrawWithAttributeOverrides;

static NSArray<NSNumber *> *_rgbaFromColor(CGColorRef color);  // fwd

static void _recordCTLine(CTLineRef line) {
    CaptureCtx *cap = _currentCtx();
    if (!cap || !line) return;
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    if (!runs) return;
    CFIndex nruns = CFArrayGetCount(runs);
    for (CFIndex i = 0; i < nruns; i++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
        CFIndex gc = CTRunGetGlyphCount(run);
        if (gc <= 0 || gc > 4096) continue;

        CFDictionaryRef attrs = CTRunGetAttributes(run);
        CTFontRef font = attrs ? (CTFontRef)CFDictionaryGetValue(attrs, kCTFontAttributeName) : NULL;

        LKS_TextDrawRecord *rec = [LKS_TextDrawRecord new];

        if (font) {
            CFStringRef fn = CTFontCopyFullName(font);
            if (fn) { rec.fontName = (__bridge NSString *)fn; CFRelease(fn); }
            CFStringRef ps = CTFontCopyPostScriptName(font);
            if (ps) { rec.postScriptName = (__bridge NSString *)ps; CFRelease(ps); }
            rec.fontSize = CTFontGetSize(font);

            CTFontSymbolicTraits t = CTFontGetSymbolicTraits(font);
            NSMutableArray *traitNames = [NSMutableArray array];
            if (t & kCTFontTraitItalic) [traitNames addObject:@"italic"];
            if (t & kCTFontTraitBold) [traitNames addObject:@"bold"];
            if (t & kCTFontTraitMonoSpace) [traitNames addObject:@"monospace"];
            rec.fontTraits = [traitNames componentsJoinedByString:@","];
        }

        // Glyphs
        CGGlyph *glyphs = malloc(sizeof(CGGlyph) * gc);
        CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
        NSMutableArray *gArr = [NSMutableArray arrayWithCapacity:gc];
        for (CFIndex k = 0; k < gc; k++) [gArr addObject:@(glyphs[k])];
        rec.glyphs = gArr;
        free(glyphs);
        rec.text = nil; // CTRun knows the original characters; populate below.

        // Try to get the actual characters from the run's string indices +
        // any source string we can dig out of the run attributes. CTRun
        // doesn't expose the original string directly, but we can walk
        // CTRunGetStringIndices and use the font's character set as a
        // best-effort cmap fallback.
        if (font) {
            NSDictionary<NSNumber *, NSString *> *gmap = _buildGlyphMap(font);
            if (gmap.count) {
                CGGlyph *gs = malloc(sizeof(CGGlyph) * gc);
                CTRunGetGlyphs(run, CFRangeMake(0, 0), gs);
                NSMutableString *txt = [NSMutableString string];
                for (CFIndex k = 0; k < gc; k++) {
                    NSString *ch = gmap[@(gs[k])];
                    [txt appendString:ch ?: @"\uFFFD"];
                }
                rec.text = txt;
                free(gs);
            }
        }

        // Foreground colour, if attached to attributes (preferred over
        // last-fill heuristic when present).
        CGColorRef fg = attrs ? (CGColorRef)CFDictionaryGetValue(attrs, kCTForegroundColorAttributeName) : NULL;
        if (fg) {
            rec.fillRGBA = _rgbaFromColor(fg);
        } else {
            rec.fillRGBA = cap->lastFillRGBA;
        }
        [cap->records addObject:rec];
    }
}

static NSArray<NSNumber *> *_rgbaFromColor(CGColorRef color) {
    if (!color) return nil;
    CGColorSpaceRef cs = CGColorGetColorSpace(color);
    CGColorRef converted = NULL;
    if (cs && CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) {
        CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (rgb) {
            converted = CGColorCreateCopyByMatchingToColorSpace(rgb, kCGRenderingIntentDefault, color, NULL);
            CGColorSpaceRelease(rgb);
        }
    }
    CGColorRef use = converted ?: color;
    size_t n = CGColorGetNumberOfComponents(use);
    const CGFloat *c = CGColorGetComponents(use);
    if (!c || n == 0) {
        if (converted) CGColorRelease(converted);
        return nil;
    }
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:4];
    if (n >= 3) {
        [arr addObject:@(c[0])];
        [arr addObject:@(c[1])];
        [arr addObject:@(c[2])];
        [arr addObject:@(n >= 4 ? c[3] : 1.0)];
    } else if (n == 2) {
        // grayscale + alpha
        [arr addObject:@(c[0])];
        [arr addObject:@(c[0])];
        [arr addObject:@(c[0])];
        [arr addObject:@(c[1])];
    } else {
        [arr addObject:@(c[0])];
        [arr addObject:@(c[0])];
        [arr addObject:@(c[0])];
        [arr addObject:@1.0];
    }
    if (converted) CGColorRelease(converted);
    return arr;
}

static void hooked_CTFontDrawGlyphs(CTFontRef font, const CGGlyph *glyphs,
                                    const CGPoint *positions, size_t count,
                                    CGContextRef ctx) {
    CaptureCtx *cap = _currentCtx();
    if (!cap || count == 0 || count > 4096) {
        orig_CTFontDrawGlyphs(font, glyphs, positions, count, ctx);
        return;
    }

    LKS_TextDrawRecord *rec = [LKS_TextDrawRecord new];

    CFStringRef fullName = CTFontCopyFullName(font);
    if (fullName) { rec.fontName = (__bridge NSString *)fullName; CFRelease(fullName); }
    CFStringRef psName = CTFontCopyPostScriptName(font);
    if (psName) { rec.postScriptName = (__bridge NSString *)psName; CFRelease(psName); }
    rec.fontSize = CTFontGetSize(font);

    CTFontSymbolicTraits t = CTFontGetSymbolicTraits(font);
    NSMutableArray *traitNames = [NSMutableArray array];
    if (t & kCTFontTraitItalic)      [traitNames addObject:@"italic"];
    if (t & kCTFontTraitBold)        [traitNames addObject:@"bold"];
    if (t & kCTFontTraitExpanded)    [traitNames addObject:@"expanded"];
    if (t & kCTFontTraitCondensed)   [traitNames addObject:@"condensed"];
    if (t & kCTFontTraitMonoSpace)   [traitNames addObject:@"monospace"];
    if (t & kCTFontTraitVertical)    [traitNames addObject:@"vertical"];
    if (t & kCTFontTraitUIOptimized) [traitNames addObject:@"uiOptimized"];
    rec.fontTraits = [traitNames componentsJoinedByString:@","];

    NSMutableArray<NSNumber *> *gArr = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSValue *> *pArr = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        [gArr addObject:@(glyphs[i])];
        [pArr addObject:[NSValue valueWithPoint:NSMakePoint(positions[i].x, positions[i].y)]];
    }
    rec.glyphs = gArr;
    rec.positions = pArr;

    // Best-effort glyph→character reversal
    NSDictionary<NSNumber *, NSString *> *gmap = _buildGlyphMap(font);
    if (gmap.count) {
        NSMutableString *txt = [NSMutableString stringWithCapacity:count];
        for (size_t i = 0; i < count; i++) {
            NSString *ch = gmap[@(glyphs[i])];
            if (ch) [txt appendString:ch];
            else    [txt appendString:@"\uFFFD"]; // unknown glyph
        }
        rec.text = txt;
    }

    rec.fillRGBA = cap->lastFillRGBA;

    [cap->records addObject:rec];

    orig_CTFontDrawGlyphs(font, glyphs, positions, count, ctx);
}

static void hooked_CGContextSetFillColorWithColor(CGContextRef ctx, CGColorRef color) {
    CaptureCtx *cap = _currentCtx();
    if (cap) {
        cap->lastFillRGBA = _rgbaFromColor(color);
    }
    orig_CGContextSetFillColorWithColor(ctx, color);
}

static void hooked_CGContextSetRGBFillColor(CGContextRef ctx, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    CaptureCtx *cap = _currentCtx();
    if (cap) {
        cap->lastFillRGBA = @[ @(r), @(g), @(b), @(a) ];
    }
    orig_CGContextSetRGBFillColor(ctx, r, g, b, a);
}

static void hooked_CTLineDraw(CTLineRef line, CGContextRef ctx) {
    _recordCTLine(line);
    if (orig_CTLineDraw) orig_CTLineDraw(line, ctx);
}

static void hooked_CTFrameDraw(CTFrameRef frame, CGContextRef ctx) {
    if (frame) {
        CFArrayRef lines = CTFrameGetLines(frame);
        if (lines) {
            CFIndex n = CFArrayGetCount(lines);
            for (CFIndex i = 0; i < n; i++) {
                _recordCTLine((CTLineRef)CFArrayGetValueAtIndex(lines, i));
            }
        }
    }
    if (orig_CTFrameDraw) orig_CTFrameDraw(frame, ctx);
}

static void hooked_CTRunDraw(CTRunRef run, CGContextRef ctx, CFRange r) {
    CaptureCtx *cap = _currentCtx();
    if (cap && run) {
        // Wrap the run in a temporary single-run line by directly recording it
        CFIndex gc = CTRunGetGlyphCount(run);
        if (gc > 0 && gc <= 4096) {
            CFDictionaryRef attrs = CTRunGetAttributes(run);
            CTFontRef font = attrs ? (CTFontRef)CFDictionaryGetValue(attrs, kCTFontAttributeName) : NULL;

            LKS_TextDrawRecord *rec = [LKS_TextDrawRecord new];
            if (font) {
                CFStringRef fn = CTFontCopyFullName(font);
                if (fn) { rec.fontName = (__bridge NSString *)fn; CFRelease(fn); }
                CFStringRef ps = CTFontCopyPostScriptName(font);
                if (ps) { rec.postScriptName = (__bridge NSString *)ps; CFRelease(ps); }
                rec.fontSize = CTFontGetSize(font);

                NSDictionary<NSNumber *, NSString *> *gmap = _buildGlyphMap(font);
                if (gmap.count) {
                    CGGlyph *gs = malloc(sizeof(CGGlyph) * gc);
                    CTRunGetGlyphs(run, CFRangeMake(0, 0), gs);
                    NSMutableString *txt = [NSMutableString string];
                    NSMutableArray *gArr = [NSMutableArray array];
                    for (CFIndex k = 0; k < gc; k++) {
                        [gArr addObject:@(gs[k])];
                        NSString *ch = gmap[@(gs[k])];
                        [txt appendString:ch ?: @"\uFFFD"];
                    }
                    rec.text = txt;
                    rec.glyphs = gArr;
                    free(gs);
                }
            }
            CGColorRef fg = attrs ? (CGColorRef)CFDictionaryGetValue(attrs, kCTForegroundColorAttributeName) : NULL;
            rec.fillRGBA = fg ? _rgbaFromColor(fg) : cap->lastFillRGBA;
            [cap->records addObject:rec];
        }
    }
    if (orig_CTRunDraw) orig_CTRunDraw(run, ctx, r);
}

// SwiftUI 14+ entry points.
static void hooked_CTFontDrawGlyphsAtPositions(CTFontRef font, const CGGlyph *g,
                                               const CGPoint *p, size_t n,
                                               CGContextRef ctx) {
    // Identical capture path as CTFontDrawGlyphs.
    if (_currentCtx() && font && n > 0 && n <= 4096) {
        // Hand off to the existing trampoline by faking the public call shape.
        // We don't want to duplicate the recording code, so we synthesize a
        // CTFontDrawGlyphs invocation against our hook (which does both the
        // capture and the forward to the real symbol).
        // BUT the real CTFontDrawGlyphs probably calls AtPositions internally,
        // which would recurse. Capture inline instead and forward to original.
        CaptureCtx *cap = _currentCtx();
        LKS_TextDrawRecord *rec = [LKS_TextDrawRecord new];
        CFStringRef fn = CTFontCopyFullName(font);
        if (fn) { rec.fontName = (__bridge NSString *)fn; CFRelease(fn); }
        CFStringRef ps = CTFontCopyPostScriptName(font);
        if (ps) { rec.postScriptName = (__bridge NSString *)ps; CFRelease(ps); }
        rec.fontSize = CTFontGetSize(font);

        NSDictionary<NSNumber *, NSString *> *gmap = _buildGlyphMap(font);
        if (gmap.count) {
            NSMutableString *txt = [NSMutableString string];
            NSMutableArray *gArr = [NSMutableArray arrayWithCapacity:n];
            for (size_t i = 0; i < n; i++) {
                [gArr addObject:@(g[i])];
                NSString *ch = gmap[@(g[i])];
                [txt appendString:ch ?: @"\uFFFD"];
            }
            rec.text = txt;
            rec.glyphs = gArr;
        }
        rec.fillRGBA = cap->lastFillRGBA;
        [cap->records addObject:rec];
    }
    if (orig_CTFontDrawGlyphsAtPositions) {
        orig_CTFontDrawGlyphsAtPositions(font, g, p, n, ctx);
    }
}

static void hooked_CTFontDrawGlyphsWithAdvances(CTFontRef font, const CGGlyph *g,
                                                const CGSize *adv, size_t n,
                                                CGContextRef ctx) {
    if (_currentCtx() && font && n > 0 && n <= 4096) {
        CaptureCtx *cap = _currentCtx();
        LKS_TextDrawRecord *rec = [LKS_TextDrawRecord new];
        CFStringRef fn = CTFontCopyFullName(font);
        if (fn) { rec.fontName = (__bridge NSString *)fn; CFRelease(fn); }
        rec.fontSize = CTFontGetSize(font);
        NSDictionary<NSNumber *, NSString *> *gmap = _buildGlyphMap(font);
        if (gmap.count) {
            NSMutableString *txt = [NSMutableString string];
            NSMutableArray *gArr = [NSMutableArray arrayWithCapacity:n];
            for (size_t i = 0; i < n; i++) {
                [gArr addObject:@(g[i])];
                NSString *ch = gmap[@(g[i])];
                [txt appendString:ch ?: @"\uFFFD"];
            }
            rec.text = txt;
            rec.glyphs = gArr;
        }
        rec.fillRGBA = cap->lastFillRGBA;
        [cap->records addObject:rec];
    }
    if (orig_CTFontDrawGlyphsWithAdvances) {
        orig_CTFontDrawGlyphsWithAdvances(font, g, adv, n, ctx);
    }
}

static void hooked_CTRunDrawWithAttributeOverrides(CTRunRef run, CGContextRef ctx,
                                                   CFRange r, CFDictionaryRef overrides) {
    // Same capture as CTRunDraw, with attribute overrides taking precedence
    // for foreground colour if SwiftUI used them to swap colour mid-render.
    CaptureCtx *cap = _currentCtx();
    if (cap && run) {
        CFIndex gc = CTRunGetGlyphCount(run);
        if (gc > 0 && gc <= 4096) {
            CFDictionaryRef attrs = CTRunGetAttributes(run);
            CTFontRef font = attrs ? (CTFontRef)CFDictionaryGetValue(attrs, kCTFontAttributeName) : NULL;
            CGColorRef fg = NULL;
            if (overrides) fg = (CGColorRef)CFDictionaryGetValue(overrides, kCTForegroundColorAttributeName);
            if (!fg && attrs) fg = (CGColorRef)CFDictionaryGetValue(attrs, kCTForegroundColorAttributeName);

            LKS_TextDrawRecord *rec = [LKS_TextDrawRecord new];
            if (font) {
                CFStringRef fn = CTFontCopyFullName(font);
                if (fn) { rec.fontName = (__bridge NSString *)fn; CFRelease(fn); }
                rec.fontSize = CTFontGetSize(font);

                NSDictionary<NSNumber *, NSString *> *gmap = _buildGlyphMap(font);
                if (gmap.count) {
                    CGGlyph *gs = malloc(sizeof(CGGlyph) * gc);
                    CTRunGetGlyphs(run, CFRangeMake(0, 0), gs);
                    NSMutableString *txt = [NSMutableString string];
                    NSMutableArray *gArr = [NSMutableArray array];
                    for (CFIndex k = 0; k < gc; k++) {
                        [gArr addObject:@(gs[k])];
                        NSString *ch = gmap[@(gs[k])];
                        [txt appendString:ch ?: @"\uFFFD"];
                    }
                    rec.text = txt;
                    rec.glyphs = gArr;
                    free(gs);
                }
            }
            rec.fillRGBA = fg ? _rgbaFromColor(fg) : cap->lastFillRGBA;
            [cap->records addObject:rec];
        }
    }
    if (orig_CTRunDrawWithAttributeOverrides) {
        orig_CTRunDrawWithAttributeOverrides(run, ctx, r, overrides);
    }
}

static void hooked_CTLineDrawWithAttributeOverrides(CTLineRef line, CGContextRef ctx,
                                                    CFDictionaryRef overrides) {
    _recordCTLine(line);
    if (orig_CTLineDrawWithAttributeOverrides) {
        orig_CTLineDrawWithAttributeOverrides(line, ctx, overrides);
    }
}

#pragma mark - Public API

@implementation LKS_TextDrawRecord
@end

@implementation LKS_TextDrawHook

+ (BOOL)installHooks {
    static atomic_bool installed = false;
    static atomic_bool succeeded = false;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&installed, &expected, true)) {
        return atomic_load(&succeeded);
    }

    // Path A: legacy LC_DYLD_INFO bind tables (works on iOS Simulator and on
    // older macOS binaries). fishhook iterates currently-loaded images and
    // also registers a callback for future images.
    struct rebinding rebs[] = {
        { "CTFontDrawGlyphs",                  (void *)hooked_CTFontDrawGlyphs,                  (void **)&orig_CTFontDrawGlyphs },
        { "CTFontDrawGlyphsAtPositions",       (void *)hooked_CTFontDrawGlyphsAtPositions,       (void **)&orig_CTFontDrawGlyphsAtPositions },
        { "CTFontDrawGlyphsWithAdvances",      (void *)hooked_CTFontDrawGlyphsWithAdvances,      (void **)&orig_CTFontDrawGlyphsWithAdvances },
        { "CGContextSetFillColorWithColor",    (void *)hooked_CGContextSetFillColorWithColor,    (void **)&orig_CGContextSetFillColorWithColor },
        { "CGContextSetRGBFillColor",          (void *)hooked_CGContextSetRGBFillColor,          (void **)&orig_CGContextSetRGBFillColor },
        { "CTLineDraw",                        (void *)hooked_CTLineDraw,                        (void **)&orig_CTLineDraw },
        { "CTLineDrawWithAttributeOverrides",  (void *)hooked_CTLineDrawWithAttributeOverrides,  (void **)&orig_CTLineDrawWithAttributeOverrides },
        { "CTFrameDraw",                       (void *)hooked_CTFrameDraw,                       (void **)&orig_CTFrameDraw },
        { "CTRunDraw",                         (void *)hooked_CTRunDraw,                         (void **)&orig_CTRunDraw },
        { "CTRunDrawWithAttributeOverrides",   (void *)hooked_CTRunDrawWithAttributeOverrides,   (void **)&orig_CTRunDrawWithAttributeOverrides },
    };
    int rc = rebind_symbols(rebs, sizeof(rebs)/sizeof(rebs[0]));

    // Path B: LC_DYLD_CHAINED_FIXUPS (macOS 14+ / iOS 17+ Apple-Silicon
    // builds). The legacy bind table is empty for these images, so we have to
    // walk the chained-fixups payload and rewrite the matching slot ourselves.
    // Resolve the originals via dlsym since fishhook's "replaced" out-pointer
    // only fires when the legacy path matched.
    if (!orig_CTFontDrawGlyphs) {
        orig_CTFontDrawGlyphs = (void *)CTFontDrawGlyphs;
    }
    if (!orig_CGContextSetFillColorWithColor) {
        orig_CGContextSetFillColorWithColor = (void *)CGContextSetFillColorWithColor;
    }
    if (!orig_CGContextSetRGBFillColor) {
        orig_CGContextSetRGBFillColor = (void *)CGContextSetRGBFillColor;
    }
    if (!orig_CTLineDraw) {
        orig_CTLineDraw = (void *)CTLineDraw;
    }
    if (!orig_CTFrameDraw) {
        orig_CTFrameDraw = (void *)CTFrameDraw;
    }
    if (!orig_CTRunDraw) {
        orig_CTRunDraw = (void *)CTRunDraw;
    }
    // For the symbols that aren't in the SDK header, fall back to dlsym so we
    // can still forward calls if our chained-fixups path landed.
    if (!orig_CTFontDrawGlyphsAtPositions) {
        orig_CTFontDrawGlyphsAtPositions = dlsym(RTLD_DEFAULT, "CTFontDrawGlyphsAtPositions");
    }
    if (!orig_CTFontDrawGlyphsWithAdvances) {
        orig_CTFontDrawGlyphsWithAdvances = dlsym(RTLD_DEFAULT, "CTFontDrawGlyphsWithAdvances");
    }
    if (!orig_CTRunDrawWithAttributeOverrides) {
        orig_CTRunDrawWithAttributeOverrides = dlsym(RTLD_DEFAULT, "CTRunDrawWithAttributeOverrides");
    }
    if (!orig_CTLineDrawWithAttributeOverrides) {
        orig_CTLineDrawWithAttributeOverrides = dlsym(RTLD_DEFAULT, "CTLineDrawWithAttributeOverrides");
    }

    struct lks_chained_rebinding chained_rebs[] = {
        { "CTFontDrawGlyphs",                  (void *)hooked_CTFontDrawGlyphs, NULL },
        { "CTFontDrawGlyphsAtPositions",       (void *)hooked_CTFontDrawGlyphsAtPositions, NULL },
        { "CTFontDrawGlyphsWithAdvances",      (void *)hooked_CTFontDrawGlyphsWithAdvances, NULL },
        { "CGContextSetFillColorWithColor",    (void *)hooked_CGContextSetFillColorWithColor, NULL },
        { "CGContextSetRGBFillColor",          (void *)hooked_CGContextSetRGBFillColor, NULL },
        { "CTLineDraw",                        (void *)hooked_CTLineDraw, NULL },
        { "CTLineDrawWithAttributeOverrides",  (void *)hooked_CTLineDrawWithAttributeOverrides, NULL },
        { "CTFrameDraw",                       (void *)hooked_CTFrameDraw, NULL },
        { "CTRunDraw",                         (void *)hooked_CTRunDraw, NULL },
        { "CTRunDrawWithAttributeOverrides",   (void *)hooked_CTRunDrawWithAttributeOverrides, NULL },
    };
    uint32_t image_count = _dyld_image_count();
    for (uint32_t i = 0; i < image_count; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        lks_chained_rebind_image(h, slide, chained_rebs,
                                 sizeof(chained_rebs)/sizeof(chained_rebs[0]));
    }

    bool ok = (rc == 0) || orig_CTFontDrawGlyphs != NULL;
    atomic_store(&succeeded, ok);
    return ok;
}

+ (NSArray<LKS_TextDrawRecord *> *)snapshotWithBlock:(void (^)(void))block {
    if (!block) return nil;
    if (![self installHooks]) {
        // Hooks failed; still run the block so callers don't have to branch,
        // but signal "no records possible" by returning nil.
        block();
        return nil;
    }
    _ensureCaptureKey();
    if (pthread_getspecific(_captureKey)) {
        // Nested snapshot — bail rather than corrupt the outer one's records.
        block();
        return nil;
    }

    CaptureCtx ctx = { .records = [NSMutableArray array], .lastFillRGBA = nil };
    pthread_setspecific(_captureKey, &ctx);
    @try {
        block();
    } @finally {
        pthread_setspecific(_captureKey, NULL);
    }
    return ctx.records;
}

@end

#endif
