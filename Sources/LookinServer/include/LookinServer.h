#ifndef LookinServer_h
#define LookinServer_h

#if TARGET_OS_IPHONE || TARGET_OS_TV || TARGET_OS_VISION
#import <UIKit/UIKit.h>
@interface UIView (LookinServer)
#elif TARGET_OS_OSX
#import <AppKit/AppKit.h>
@interface NSView (LookinServer)
#endif

/// Figma 节点 ID，用于视觉还原精确元素匹配
@property(nonatomic, copy, nullable) NSString *lks_figmaNodeId;

@end

#endif /* LookinServer_h */
