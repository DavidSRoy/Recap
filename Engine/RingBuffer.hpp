#pragma once
#include <atomic>
#include <cstddef>
#include <vector>

// Lock-free SPSC ring buffer for PCM float frames.
class RingBuffer {
public:
    explicit RingBuffer(size_t capacityFrames);
    size_t push(const float* data, size_t frames);
    size_t pop(float* out, size_t maxFrames);
    size_t size() const;

private:
    const size_t capacity_;
    std::vector<float> buffer_;
    std::atomic<size_t> head_{0};
    std::atomic<size_t> tail_{0};
};
