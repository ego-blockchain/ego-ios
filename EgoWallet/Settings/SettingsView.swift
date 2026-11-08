import EgoKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var phrase: [String]?
    @State private var problem: String?
    @State private var confirmRemove = false
    @State private var knownGateways = 0
    @State private var copied = false
    @StateObject private var gate = AuthGate()


    @ObservedObject private var blocklist = ChatBlocklist.shared

    var body: some View {
        Group {
            ZStack {
                AuroraBackground(intensity: 0.5, colors: [Brand.sky, Brand.violet, Brand.mint])
                ScrollView {
                    // The same column as the other tabs, so the title and cards line up while swiping.
                    VStack(alignment: .leading, spacing: 16) {
                        PageTitle("Settings")
                        VStack(spacing: 10) {
                            link(ProfilePage(), "person.crop.circle.fill", Brand.violet, "Chat profile", "Your name and picture in the community chat")
                            link(GovernancePage(), "building.columns.fill", Brand.lime, "Governance", "Vote on proposals and create your own")
                            link(StakingPage(), "lock.circle.fill", Brand.mint, "Staking", "Lock EGOC to secure the network and to vote")
                        }
                        walletCard
                        BundleCard()
                        AuthenticatorCard(address: app.address)
                        networkCard
                        if !blocklist.blocked.isEmpty { blockedCard }
                        GlassCard {
                            SectionLabel(text: "About")
                            Link(destination: Legal.terms) { rowLabel("Terms of Service", icon: "doc.text") }
                            Link(destination: Legal.privacy) { rowLabel("Privacy Policy", icon: "hand.raised") }
                        }
                        Button { app.lock() } label: { Label("Lock wallet", systemImage: "lock.fill") }
                            .buttonStyle(OutlineButtonStyle())
                        VStack(spacing: 8) {
                            Button { confirmRemove = true } label: { Label("Log out", systemImage: "rectangle.portrait.and.arrow.right") }
                                .buttonStyle(OutlineButtonStyle(tint: Brand.danger))
                            Text("Logging out removes the wallet from this iPhone. Your coins stay on the network; you'll need your 24 words or raw seed to log back in.")
                                .font(.caption).foregroundStyle(Brand.muted)
                        }
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .authGate(gate)
            .confirmationDialog("Log out of Ego Wallet?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Log out", role: .destructive) { Task { await logOut() } }
            } message: {
                Text("This removes the wallet from this iPhone. Only do it if your 24 words or raw seed are written down. Without them the wallet is gone for good.")
            }
            .task { knownGateways = await app.directory.known.count }
            .onDisappear {
                phrase = nil
                copied = false
            }
        }
    }

    private func link<V: Hashable>(_ value: V, _ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        NavigationLink(value: value) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.body, design: .rounded, weight: .bold)).foregroundStyle(Brand.text)
                    Text(detail).font(.caption).foregroundStyle(Brand.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.muted)
            }
            .padding(14)
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .background(Brand.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Brand.sky).frame(width: 22)
            Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.text)
            Spacer()
            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Brand.muted)
        }
    }

    private var walletCard: some View {
        GlassCard {
            SectionLabel(text: "Wallet")
            VStack(alignment: .leading, spacing: 6) {
                Text("Address").font(.caption).foregroundStyle(Brand.muted)
                Text(app.address)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Brand.text)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = app.address
                    Haptics.success()
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(OutlineButtonStyle())
                if phrase == nil {
                    Button { Task { await reveal() } } label: { Label("Recovery phrase", systemImage: "key.fill") }
                        .buttonStyle(OutlineButtonStyle(tint: Brand.warning))
                }
            }
            if let phrase {
                PhraseGrid(words: phrase)
                Button("Hide recovery phrase") { self.phrase = nil }.buttonStyle(GhostButtonStyle())
            }
            if let problem { ProblemBanner(text: problem) }
        }
    }

    private var networkCard: some View {
        GlassCard {
            SectionLabel(text: "Network")
            infoRow("Internet", app.online ? "Connected" : "Offline", ok: app.online)
            infoRow("Connected through", app.gatewayHost ?? "Not connected yet", ok: app.gatewayHost != nil)
            infoRow("Gateways this phone knows", "\(knownGateways)", ok: nil)
            Text("Phones reach the Ego network through Ego Desktop computers that offer to act as gateways. Gateways only pass messages along. Your keys and signatures stay on this iPhone.")
                .font(.caption).foregroundStyle(Brand.muted)
        }
    }

    private func infoRow(_ label: String, _ value: String, ok: Bool?) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Brand.muted)
            Spacer()
            if let ok { Circle().fill(ok ? Brand.mint : Brand.warning).frame(width: 7, height: 7) }
            Text(value).font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Brand.text)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private var blockedCard: some View {
        GlassCard {
            SectionLabel(text: "Blocked in chat")
            ForEach(blocklist.blocked, id: \.self) { address in
                HStack {
                    Text(shortAddress(address)).font(.system(.footnote, design: .monospaced)).foregroundStyle(Brand.text)
                    Spacer()
                    Button("Unblock") { blocklist.unblock(address) }
                        .font(.footnote.weight(.semibold)).foregroundStyle(Brand.lime)
                }
            }
            Text("Their messages don't show on this iPhone.").font(.caption).foregroundStyle(Brand.muted)
        }
    }

    private func logOut() async {
        do {
            try await app.logOut()
            Authenticator.shared.forget()
        } catch VaultError.cancelled {
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
    }

    private func reveal() async {
        guard await gate.require(.reveal) else { return }
        do {
            phrase = try await app.revealPhrase()
            problem = nil
        } catch VaultError.cancelled {
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
    }
}
