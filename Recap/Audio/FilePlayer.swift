import Foundation
import AVFoundation

final class FilePlayer {
    func play(url: URL, realtime: Bool, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        // Day 1: read file, push 16 kHz mono frames at real-time pacing if realtime=true
    }

    func stop() {
        // Day 1
    }
}
