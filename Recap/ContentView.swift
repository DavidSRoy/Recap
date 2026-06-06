import SwiftUI

struct ContentView: View {
    @Environment(RecapModel.self) private var model

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Transcript")
                        .font(.headline)
                        .padding(.horizontal)
                    Spacer()
                    Text("\(model.segments.count) segments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing)
                }
                .padding(.vertical, 8)
                Divider()
                TranscriptView(segments: model.segments)
            }
            .frame(minWidth: 320)

            VStack(spacing: 0) {
                BulletsView(bullets: model.bullets)
                    .frame(maxHeight: 200)
                Divider()
                SummaryView(summary: model.summary)
            }
            .frame(minWidth: 320)
        }
        .frame(minWidth: 700, minHeight: 500)
        .overlay(alignment: .bottomTrailing) {
            MetricsOverlay().padding()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if model.isRunning { model.stop() }
                    else { model.startMic() }
                } label: {
                    Label(
                        model.isRunning ? "Stop" : "Start Mic",
                        systemImage: model.isRunning ? "stop.circle.fill" : "mic.circle.fill"
                    )
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(RecapModel())
}
