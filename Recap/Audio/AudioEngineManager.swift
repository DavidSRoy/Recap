import Foundation
import AVFoundation

enum AudioError: Error {
    case conversionFailed
    case permissionDenied
    case noInputDevice
}

final class AudioEngineManager {
    private let engine = AVAudioEngine()

    // Called from AVAudioEngine's audio thread — must be @Sendable
    var onSamples: (@Sendable ([Float]) -> Void)?

    static let targetFormat = AVAudioFormat(
        standardFormatWithSampleRate: 16_000,
        channels: 1
    )!

    func startCapture() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw AudioError.conversionFailed
        }

        let ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
        // Capture by value so tap closure doesn't touch @MainActor storage
        let onSamples = self.onSamples

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let outCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: outCapacity) else { return }
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            onSamples?(samples)
        }

        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
