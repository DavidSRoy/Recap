import Foundation
import AVFoundation

final class AudioEngineManager {
    private let engine = AVAudioEngine()
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    func startCapture() throws {
        // Day 1: install tap at 16 kHz mono, push frames to EngineBridge
    }

    func stop() {
        engine.stop()
    }
}
