#if defined(SHOULD_COMPILE_LOOKIN_SERVER) && TARGET_OS_OSX
//
//  LKS_TextDrawHook.h
//  LookinServer
//
//  Installs fishhook-based interposers for the CoreText / CoreGraphics
//  symbols SwiftUI uses to rasterise text, and exposes a snapshot API that
//  collects the captured records for one targeted draw pass.
//
//  Recording is *opt-in per thread*: hooks are no-op forwards when the
//  thread-local capture flag is off, so calls from the host application's
//  normal render path pay essentially zero overhead.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// One CoreText draw event captured during a snapshot pass.
@interface LKS_TextDrawRecord : NSObject
@property(nonatomic, copy, nullable) NSString *fontName;       ///< CTFontCopyFullName
@property(nonatomic, copy, nullable) NSString *postScriptName; ///< CTFontCopyPostScriptName
@property(nonatomic, assign) CGFloat fontSize;                 ///< point size
@property(nonatomic, copy, nullable) NSString *fontTraits;     ///< symbolic traits
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *glyphs;
@property(nonatomic, copy, nullable) NSArray<NSValue *> *positions; ///< NSValue<NSPoint>
@property(nonatomic, copy, nullable) NSString *text;           ///< glyph→char reversed string
/// Last fillColor seen on the same context immediately before this draw.
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *fillRGBA;
@end

@interface LKS_TextDrawHook : NSObject

/// Idempotently install fishhook interposers. Safe to call repeatedly.
/// Returns YES on success, NO if any hook installation failed.
+ (BOOL)installHooks;

/// Mark the calling thread as the recording thread, run @c block, then drain
/// and return all draw records captured during it. Records are tagged with
/// the most-recent fillRGBA observed prior to each glyph run.
///
/// Nested snapshot passes on the same thread are not supported and return nil.
+ (nullable NSArray<LKS_TextDrawRecord *> *)snapshotWithBlock:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END

#endif
