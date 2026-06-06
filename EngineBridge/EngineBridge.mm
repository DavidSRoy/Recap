#import "EngineBridge.h"
#include "../Engine/RingBuffer.hpp"
#include "../Engine/MetricsCollector.hpp"
#include <memory>

@implementation EngineBridge {
    std::unique_ptr<RingBuffer> _ring;
}

- (instancetype)initWithCapacity:(NSUInteger)frames {
    if (self = [super init]) {
        _ring = std::make_unique<RingBuffer>(frames);
    }
    return self;
}

- (void)pushPCM:(const float *)data count:(NSUInteger)count {
    _ring->push(data, count);
}

- (NSUInteger)popPCM:(float *)out maxCount:(NSUInteger)max {
    return _ring->pop(out, max);
}

- (uint64_t)nowNs {
    return nowNs();
}

- (double)rssMb {
    return rssMb();
}

@end
