// Single-producer / single-consumer lock-free ring buffer for float audio frames.
// Producer: WASAPI capture thread. Consumer: Dart FFI poll thread.
#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

class FloatRingBuffer {
 public:
  explicit FloatRingBuffer(size_t capacity_frames) {
    size_t cap = 1;
    while (cap < capacity_frames) cap <<= 1;
    buf_.resize(cap, 0.0f);
    mask_ = cap - 1;
  }

  void reset() {
    head_.store(0, std::memory_order_relaxed);
    tail_.store(0, std::memory_order_relaxed);
  }

  size_t available() const {
    uint64_t head = head_.load(std::memory_order_acquire);
    uint64_t tail = tail_.load(std::memory_order_acquire);
    return static_cast<size_t>(head - tail);
  }

  size_t capacity() const { return buf_.size(); }

  // Writes n frames; on overflow the oldest frames are dropped.
  // Returns the number of frames actually written (== n unless n > capacity).
  size_t write(const float* data, size_t n) {
    size_t cap = buf_.size();
    if (n > cap) {
      data += n - cap;
      n = cap;
    }
    uint64_t head = head_.load(std::memory_order_relaxed);
    uint64_t tail = tail_.load(std::memory_order_acquire);
    size_t free = cap - static_cast<size_t>(head - tail);
    if (n > free) {
      size_t drop = n - free;
      tail_.store(tail + drop, std::memory_order_release);
      tail += drop;
    }
    for (size_t i = 0; i < n; ++i) {
      buf_[(head + i) & mask_] = data[i];
    }
    head_.store(head + n, std::memory_order_release);
    return n;
  }

  // Writes n frames of silence (used for AUDCLNT_BUFFERFLAGS_SILENT packets).
  void write_zeros(size_t n) {
    size_t cap = buf_.size();
    if (n > cap) n = cap;
    uint64_t head = head_.load(std::memory_order_relaxed);
    uint64_t tail = tail_.load(std::memory_order_acquire);
    size_t free = cap - static_cast<size_t>(head - tail);
    if (n > free) {
      size_t drop = n - free;
      tail_.store(tail + drop, std::memory_order_release);
      tail += drop;
    }
    for (size_t i = 0; i < n; ++i) {
      buf_[(head + i) & mask_] = 0.0f;
    }
    head_.store(head + n, std::memory_order_release);
  }

  // Reads up to n frames; returns the number actually read (may be 0).
  size_t read(float* out, size_t n) {
    uint64_t tail = tail_.load(std::memory_order_relaxed);
    uint64_t head = head_.load(std::memory_order_acquire);
    size_t avail = static_cast<size_t>(head - tail);
    if (n > avail) n = avail;
    for (size_t i = 0; i < n; ++i) {
      out[i] = buf_[(tail + i) & mask_];
    }
    tail_.store(tail + n, std::memory_order_release);
    return n;
  }

 private:
  std::vector<float> buf_;
  size_t mask_ = 0;
  std::atomic<uint64_t> head_{0};  // frames written (monotonic)
  std::atomic<uint64_t> tail_{0};  // frames read    (monotonic)
};
