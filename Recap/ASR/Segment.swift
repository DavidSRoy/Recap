import Foundation

struct Segment: Codable, Identifiable {
    let id: Int
    let startMs: Int
    let endMs: Int
    let text: String
    let isFinal: Bool
}
