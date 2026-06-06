import SwiftUI

struct SummaryView: View {
    let summary: String

    var body: some View {
        ScrollView {
            Text(summary.isEmpty ? "Summary will appear here…" : summary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
