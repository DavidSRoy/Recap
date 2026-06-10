import SwiftUI

struct MetricsOverlay: View {
    @Environment(RecapModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            row("TTFT", model.lastTTFTMs.map { "\($0) ms" } ?? "—")
            row("Total", model.lastTotalMs.map { "\($0) ms" } ?? "—")
            row("Tokens in/out", tokensString)
            row("RSS", model.currentRssMb.map { String(format: "%.1f MB", $0) } ?? "—")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.primary)
        }
    }

    private var tokensString: String {
        let tin = model.lastTokensIn.map(String.init) ?? "—"
        let tout = model.lastTokensOut.map(String.init) ?? "—"
        return "\(tin) / \(tout)"
    }
}
