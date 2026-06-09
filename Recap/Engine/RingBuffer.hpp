#pragma once
#include <atomic>
#include <cstddef>
#include <vector>

// Lock-free SPSC ring buffer for PCM float frames.
// Producer: audio thread (push). Consumer: ASR loop (pop / peekTail / clear).
// "head" is the next write index, "tail" the next read index — both modulo capacity_.
class RingBuffer {
public:
    explicit RingBuffer(size_t capacityFrames);
    size_t push(const float* data, size_t frames);
    size_t pop(float* out, size_t maxFrames);
    size_t peekTail(float* out, size_t maxFrames) const;
    size_t size() const;
    void clear();

private:
    const size_t capacity_;
    std::vector<float> buffer_;
    std::atomic<size_t> head_{0};
    std::atomic<size_t> tail_{0};
};
