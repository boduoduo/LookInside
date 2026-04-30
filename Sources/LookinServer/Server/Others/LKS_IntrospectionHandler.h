#if defined(SHOULD_COMPILE_LOOKIN_SERVER)
//
//  LKS_IntrospectionHandler.h
//  LookinServer
//
//  Built-in object introspection helper used by the lookinside CLI's
//  `ivars` subcommand. Returns a serialisable dictionary describing an
//  object's class chain, ivars, recognised AppKit/AX info, and a small
//  set of Swift-level peeks for SwiftUI internal types.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LKS_IntrospectionHandler : NSObject

/// Returns a plist/JSON-friendly dictionary describing @c object. The
/// structure is intentionally loose so that future fields can be added
/// without changing the wire format. Always returns a non-nil result.
+ (NSDictionary *)introspectObject:(nullable id)object;

@end

NS_ASSUME_NONNULL_END

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
