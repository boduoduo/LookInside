#ifdef SHOULD_COMPILE_LOOKIN_SERVER 

//
//  LookinConnectionAttachment.m
//  Lookin
//
//  Created by Li Kai on 2019/2/15.
//  https://lookin.work
//



#import "LookinConnectionAttachment.h"
#import "LookinDefines.h"
#import "NSObject+Lookin.h"

static NSString * const Key_Data = @"0";
static NSString * const Key_DataType = @"1";

@interface LookinConnectionAttachment ()

@end

@implementation LookinConnectionAttachment

- (instancetype)init {
    if (self = [super init]) {
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
    
    [aCoder encodeObject:[self.data lookin_encodedObjectWithType:self.dataType] forKey:Key_Data];
    [aCoder encodeInteger:self.dataType forKey:Key_DataType];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super init]) {
        self.dataType = [aDecoder decodeIntegerForKey:Key_DataType];
        // Use decodeObjectOfClasses:forKey: with an explicit allow-list so
        // that the secure-coding warning generator never sees a single-element
        // {NSObject} allowed-classes set and recurse-crashes on macOS 26.
        //
        // The bug:  NSCoder _warnAboutNSObjectInAllowedClassesWithException
        //           → _allowedClassesDescriptionForClasses_block_invoke
        //           → +[NSObject description] → CFStringFormat (recurses → SIGBUS)
        // fires when the unarchiver decodes a deeply nested NSDictionary tree
        // (such as SwiftUI's accessibilityDebugData with 30 000+ nodes) using
        // a default `decodeObjectForKey:` call, because the default allow-set
        // is just {NSObject} and the warning path mishandles its own
        // description string. Listing every class our wire payloads carry
        // lets secure decoding succeed without ever touching that path.
        NSSet<Class> *allowed = [LookinConnectionAttachment _lks_allowedDataPayloadClasses];
        id raw = [aDecoder decodeObjectOfClasses:allowed forKey:Key_Data];
        self.data = [raw lookin_decodedObjectWithType:self.dataType];
    }
    return self;
}

/// Concrete classes that legitimate Lookin RPC payloads carry inside
/// LookinConnectionAttachment.data. NSObject is intentionally absent —
/// see -initWithCoder: for the macOS 26 NSKeyedUnarchiver bug we're
/// avoiding.
+ (NSSet<Class> *)_lks_allowedDataPayloadClasses {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *m = [NSMutableSet set];
        // Foundation container + primitive types (the JSON-style leaves).
        for (Class c in @[
            [NSDictionary class], [NSMutableDictionary class],
            [NSArray class], [NSMutableArray class],
            [NSSet class], [NSMutableSet class],
            [NSString class], [NSMutableString class],
            [NSNumber class], [NSData class], [NSMutableData class],
            [NSDate class], [NSNull class], [NSValue class],
            [NSURL class], [NSUUID class],
        ]) {
            [m addObject:c];
        }
        // All Lookin object types that participate in wire payloads. Looked
        // up by name so a missing implementation (e.g. an iOS-only class
        // when running on macOS) is silently skipped instead of failing
        // compilation.
        for (NSString *name in @[
            @"LookinAppInfo",
            @"LookinAttribute",
            @"LookinAttributeModification",
            @"LookinAttributesGroup",
            @"LookinAttributesSection",
            @"LookinAutoLayoutConstraint",
            @"LookinCustomAttrModification",
            @"LookinCustomDisplayItemInfo",
            @"LookinDisplayItem",
            @"LookinDisplayItemDetail",
            @"LookinEventHandler",
            @"LookinHierarchyFile",
            @"LookinHierarchyInfo",
            @"LookinObject",
            @"LookinStaticAsyncUpdateTask",
            @"LookinTuple",
        ]) {
            Class c = NSClassFromString(name);
            if (c) [m addObject:c];
        }
        set = [m copy];
    });
    return set;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

@end

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
