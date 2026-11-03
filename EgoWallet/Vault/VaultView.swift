import EgoKit
import SwiftUI

/// Wallet vault, kept to one setting: the most EGOC that can leave this wallet in a day.
/// Waiting sends, a pending change and a freeze made elsewhere show only when they exist.
struct VaultView: View {
    @EnvironmentObject private var app: AppModel
    @State private var status: Vault.Status?
    @State private var problem: String?
    @State private var note: String?
    @State private var busy = false
    @State private var limitText = ""

    /// How long a send above the limit, or raising the limit, waits. The network needs one;
    /// a new vault gets a day.
    static let defaultDelay: Int64 = 24 * 3600

    private var wait: String {
        let secs = status?.vault?.settings.delay ?? Self.defaultDelay
        let h = secs / 3600
        return h >= 48 && h % 24 == 0 ? "\(h / 24) days" : h == 1 ? "1 hour" : "\(h) hours"
    }

    var body: some View {
        GlassPage {
            PageTitle("Wallet vault", subtitle: "Set the most that can leave in a day")
            if let note { NoteCard(text: note, icon: "checkmark.circle.fill", tint: Brand.mint) }
            if let problem { ProblemBanner(text: problem) }
            if let status {
                if !status.active {
                    NoteCard(text: "The vault isn't switched on in the network yet.", icon: "clock.fill", tint: Brand.warning)
                }
                if let vault = status.vault {
                    if let pending = vault.pending { pendingCard(pending) }
                    if !vault.queue.isEmpty { queueCard(vault) }
                    if vault.frozen { frozenCard(vault) }
                    limitCard(vault)
                } else if status.active {
                    limitCard(nil)
                }
            } else if problem == nil {
                ProgressView().tint(Brand.lime).frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: Cards

    private func limitCard(_ v: Vault.View?) -> some View {
        GlassCard {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Brand.ink)
                    .frame(width: 52, height: 52)
                    .background(Brand.lime, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Brand.lime.opacity(0.45), radius: 12, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily limit").font(.footnote).foregroundStyle(Brand.muted)
                    Text(v.map { "\(Amount.format($0.settings.limit)) EGOC" } ?? "Not set")
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                        .foregroundStyle(Brand.text)
                }
            }
            if let v {
                Text("\(Amount.format(v.leftToday)) EGOC left today").font(.subheadline).foregroundStyle(Brand.muted)
            } else {
                Text("No more than this can leave your wallet in one day, even if someone gets your key.")
                    .font(.subheadline).foregroundStyle(Brand.muted)
            }
            HStack(spacing: 10) {
                TextField(v == nil ? "Like 100" : "New limit", text: $limitText)
                    .keyboardType(.decimalPad)
                    .glassInput()
                Text("EGOC").font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Brand.muted)
            }
            Button(busy ? "Saving…" : v == nil ? "Turn on" : "Save") { Task { await save(v) } }
                .buttonStyle(GlowButtonStyle())
                .disabled(busy || Amount.parse(limitText) == nil)
            if v != nil {
                Text("A lower limit starts right away. A higher one starts in \(wait).")
                    .font(.caption).foregroundStyle(Brand.muted)
            }
        }
    }

    private func frozenCard(_ v: Vault.View) -> some View {
        GlassCard(tint: Brand.sky) {
            Label("This wallet is frozen", systemImage: "snowflake")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Brand.sky)
            Button("Unfreeze") { act("The wallet unfreezes in \(wait).") { try await app.unfreezeVault() } }
                .buttonStyle(OutlineButtonStyle())
                .disabled(busy || v.pending?.kind == "unfreeze")
        }
    }

    private func pendingCard(_ pending: Vault.PendingChange) -> some View {
        GlassCard(tint: Brand.warning) {
            Label("\(pendingText(pending)) on \(date(pending.at))", systemImage: "exclamationmark.triangle.fill")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Brand.warning)
            Text("If this wasn't you, cancel it now. Someone may have your key.")
                .font(.footnote).foregroundStyle(Brand.text)
            Button("Cancel it") {
                act("Cancelled.") { try await app.cancelInVault(target: Vault.cancelChange) }
            }
            .buttonStyle(OutlineButtonStyle(tint: Brand.danger))
            .disabled(busy)
        }
    }

    private func queueCard(_ v: Vault.View) -> some View {
        GlassCard {
            SectionLabel(text: "Waiting sends")
            ForEach(v.queue) { q in
                let ready = Double(q.at) <= Date().timeIntervalSince1970
                let mine = app.vaultMine.contains(q.id)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Amount.format(q.amount)) EGOC → \(shortAddress(q.to))")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.text)
                        Text(ready ? "Going out now" : "Goes out \(date(q.at))").font(.caption).foregroundStyle(Brand.muted)
                        if !mine {
                            Text("Not started on this iPhone").font(.caption.weight(.semibold)).foregroundStyle(Brand.warning)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { act("Cancelled.") { try await app.cancelInVault(target: q.id) } }
                        .font(.system(.footnote, design: .rounded, weight: .bold))
                        .foregroundStyle(Brand.danger)
                        .disabled(busy)
                }
            }
        }
    }

    // MARK: Helpers

    private func date(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .shortened)
    }

    private func pendingText(_ pending: Vault.PendingChange) -> String {
        switch pending.kind {
        case "off": return "The vault turns off"
        case "unfreeze": return "The wallet unfreezes"
        default:
            if let s = pending.settings { return "The limit goes up to \(Amount.format(s.limit)) EGOC" }
            return "The vault changes"
        }
    }

    private func save(_ v: Vault.View?) async {
        guard let limit = Amount.parse(limitText) else { return }
        var settings = v?.settings ?? Vault.Settings(limit: limit, delay: Self.defaultDelay)
        settings.limit = limit
        if settings.highLimit > 0 && settings.highLimit <= limit {
            settings.highLimit = 0
            settings.highDelay = 0
        }
        let raising = v.map { limit > $0.settings.limit } ?? false
        await run(raising ? "Saved. The higher limit starts in \(wait)." : "Saved.") {
            try await app.saveVault(settings)
            limitText = ""
        }
    }

    private func load() async {
        do {
            let s = try await app.vaultStatus()
            status = s
            if s.vault != nil { app.askForAlerts() }
            problem = nil
            if await app.sendDueVaultSends(s) > 0 {
                note = "A waiting send's time is up, so it went out."
            }
        } catch {
            problem = app.message(for: error)
        }
    }

    private func act(_ success: String, _ work: @escaping () async throws -> Void) {
        Task { await run(success, work) }
    }

    private func run(_ success: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            Haptics.success()
            note = success
            problem = nil
            await load()
        } catch {
            note = nil
            problem = app.message(for: error)
        }
    }
}
