#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EngineBridge : NSObject
- (instancetype)initWithCapacity:(NSUInteger)frames;
- (void)pushPCM:(const float *)data count:(NSUInteger)count;
- (NSUInteger)popPCM:(float *)out maxCount:(NSUInteger)max;
- (NSUInteger)peekTail:(float *)out maxCount:(NSUInteger)max;
- (NSUInteger)frameCount;
- (void)clear;
- (uint64_t)nowNs;
- (double)rssMb;
@end

NS_ASSUME_NONNULL_END
