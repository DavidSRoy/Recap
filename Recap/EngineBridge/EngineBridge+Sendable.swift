import Foundation

// The underlying RingBuffer is SPSC lock-free (atomic head/tail), and rssMb /
// nowNs are stateless. As long as callers respect the single-producer /
// single-consumer contract for push/pop, EngineBridge is safe to share across
// the audio thread and the ASR loop.
extension EngineBridge: @unchecked Sendable {}
