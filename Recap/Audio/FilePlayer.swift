import Foundation
import AVFoundation

final class FilePlayer {
    var onSamples: (@Sendable ([Float]) -> Void)?

    private var playTask: Task<Void, Never>?

    func play(url: URL, realtime: Bool) throws {
        let audioFile = try AVAudioFile(forReading: url)
        let inputFormat = audioFile.processingFormat
        let outputFormat = AudioEngineManager.targetFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioError.conversionFailed
        }

        let outputChunk: AVAudioFrameCount = 1_600  // 100 ms at 16 kHz
        let inputChunk = AVAudioFrameCount(
            (Double(outputChunk) * inputFormat.sampleRate / outputFormat.sampleRate).rounded(.up)
        )

        let onSamples = self.onSamples  // capture by value

        playTask = Task.detached {
            guard let inputBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputChunk) else { return }
            while !Task.isCancelled {
                do { try audioFile.read(into: inputBuf, frameCount: inputChunk) }
                catch { break }
                guard inputBuf.frameLength > 0 else { break }

                guard let outputBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputChunk) else { continue }
                var err: NSError?
                // AVAudioConverter is not Sendable; capture locally per call
                converter.convert(to: outputBuf, error: &err) { _, status in
                    status.pointee = .haveData
                    return inputBuf
                }
                guard err == nil, let data = outputBuf.floatChannelData, outputBuf.frameLength > 0 else { continue }
                let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(outputBuf.frameLength)))
                onSamples?(samples)

                if realtime {
                    try? await Task.sleep(nanoseconds: 100_000_000)  // pace to real time
                }
            }
        }
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
    }
}
