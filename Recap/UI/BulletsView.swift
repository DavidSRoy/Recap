import SwiftUI

struct BulletsView: View {
    let bullets: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(Color.accentColor)
                    Text(bullet)
                }
            }
        }
        .padding()
    }
}
