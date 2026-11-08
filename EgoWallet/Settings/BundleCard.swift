import EgoKit
import SwiftUI

struct BundleCard: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var account = AccountStore.shared
    @State private var copied = false
    @State private var showQR = false

    var body: some View {
        GlassCard {
            SectionLabel(text: "Bundle ID")
            if let bundle = account.desktop?.bundle, !bundle.isEmpty {
                Text(bundle)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Brand.text)
                    .lineLimit(4)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = bundle
                        Haptics.success()
                        copied = true
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(OutlineButtonStyle())
                    ShareLink(item: bundle) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(OutlineButtonStyle())
                    Button { showQR.toggle() } label: { Label("QR", systemImage: "qrcode") }
                        .buttonStyle(OutlineButtonStyle())
                }
                if showQR, let image = QRCode.image(for: bundle) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220)
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: .infinity)
                }
                Text("The same Bundle ID as your Ego Desktop. Delete it there and make a new one, and this one changes too.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            } else {
                Text(account.loading
                     ? "Looking for your Ego Desktop's Bundle ID…"
                     : "Open Ego Desktop with this wallet on a computer once. Its Bundle ID then shows here, even while that computer is off.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
            if let problem = account.problem {
                Text(problem).font(.caption).foregroundStyle(Brand.warning)
            }
        }
        .task { await account.refresh(app) }
    }
}
