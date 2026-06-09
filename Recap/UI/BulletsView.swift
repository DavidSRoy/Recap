import SwiftUI

struct BulletsView: View {
    let bullets: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if bullets.isEmpty {
                    Text("Bullets will appear here…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(Color.accentColor)
                            Text(bullet)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
