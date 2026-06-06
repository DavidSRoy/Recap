import SwiftUI

struct TranscriptView: View {
    let segments: [Segment]

    var body: some View {
        List(segments) { seg in
            Text(seg.text)
                .font(.body)
                .foregroundStyle(seg.isFinal ? .primary : .secondary)
        }
    }
}
