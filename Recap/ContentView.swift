import SwiftUI

struct ContentView: View {
    @State private var segments: [Segment] = []
    @State private var bullets: [String] = []
    @State private var summary: String = ""

    var body: some View {
        HSplitView {
            TranscriptView(segments: segments)
                .frame(minWidth: 300)

            VStack(spacing: 0) {
                BulletsView(bullets: bullets)
                    .frame(maxHeight: 200)
                Divider()
                SummaryView(summary: summary)
            }
            .frame(minWidth: 300)
        }
        .frame(minWidth: 700, minHeight: 500)
        .overlay(alignment: .bottomTrailing) {
            MetricsOverlay()
                .padding()
        }
    }
}

#Preview {
    ContentView()
}
