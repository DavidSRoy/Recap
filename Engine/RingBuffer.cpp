#include "RingBuffer.hpp"
#include <algorithm>

RingBuffer::RingBuffer(size_t capacityFrames)
    : capacity_(capacityFrames + 1), buffer_(capacityFrames + 1, 0.0f) {}

size_t RingBuffer::push(const float* data, size_t frames) {
    const size_t head = head_.load(std::memory_order_relaxed);
    const size_t tail = tail_.load(std::memory_order_acquire);
    const size_t avail = (tail - head - 1 + capacity_) % capacity_;
    const size_t n = std::min(frames, avail);
    for (size_t i = 0; i < n; ++i)
        buffer_[(head + i) % capacity_] = data[i];
    head_.store((head + n) % capacity_, std::memory_order_release);
    return n;
}

size_t RingBuffer::pop(float* out, size_t maxFrames) {
    const size_t tail = tail_.load(std::memory_order_relaxed);
    const size_t head = head_.load(std::memory_order_acquire);
    const size_t avail = (head - tail + capacity_) % capacity_;
    const size_t n = std::min(maxFrames, avail);
    for (size_t i = 0; i < n; ++i)
        out[i] = buffer_[(tail + i) % capacity_];
    tail_.store((tail + n) % capacity_, std::memory_order_release);
    return n;
}

size_t RingBuffer::size() const {
    const size_t head = head_.load(std::memory_order_acquire);
    const size_t tail = tail_.load(std::memory_order_acquire);
    return (head - tail + capacity_) % capacity_;
}
