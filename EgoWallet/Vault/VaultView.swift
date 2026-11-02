import EgoKit
import SwiftUI

/// Wallet vault: protect this wallet, watch and cancel waiting sends, freeze and sweep,
/// protect other wallets as their guardian, and approve a desktop's large send as its second key.
struct VaultView: View {
    @EnvironmentObject private var app: AppModel
    @State private var status: Vault.Status?
    @State private var problem: String?
    @State private var note: String?
    @State private var busy = false
    @State private var editing = false
    @State private var scanning = false
    @State private var requestText = ""
    @State private var request: Vault.ApprovalRequest?
    @State private var approval: String?
    @State private var confirm: Confirm?

    /// The vault actions that ask once more before they go out.
    private enum Confirm: Identifiable {
        case freeze, sweep(String), off, freezeOther(String)
        var id: String {
            switch self {
            case .freeze: return "freeze"
            case .sweep: return "sweep"
            case .off: return "off"
            case .freezeOther(let o): return "freeze/\(o)"
            }
        }
    }

    var body: some View {
        GlassPage {
            PageTitle("Wallet vault", subtitle: "Slow down anyone who gets your key")
            if let note { NoteCard(text: note, icon: "checkmark.circle.fill", tint: Brand.mint) }
            if let problem { ProblemBanner(text: problem) }
            if let status {
                if !status.active {
                    NoteCard(text: "The vault isn't switched on in the network yet. It starts once the Ego nodes run version 0.3.673.",
                             icon: "clock.fill", tint: Brand.warning)
                }
                if let vault = status.vault {
                    hero(vault)
                    if let pending = vault.pending { pendingCard(pending) }
                    if !vault.queue.isEmpty { queueCard(vault) }
                    emergency(vault)
                    if editing { settingsCard(vault.settings) } else {
                        Button { withAnimation(.snappy) { editing = true } } label: {
                            Label("Change settings", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                } else if status.active {
                    intro
                    settingsCard(nil)
                }
                if !status.helping.isEmpty {
                    SectionLabel(text: "Vaults you protect").frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    ForEach(status.helping) { v in helped(v) }
                }
            } else if problem == nil {
                ProgressView().tint(Brand.lime).frame(maxWidth: .infinity).padding(.top, 40)
            }
            approveCard
            if let vault = status?.vault {
                Button("Turn the vault off") { confirm = .off }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(busy || vault.pending?.kind == "off")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $scanning) {
            QRScanner { code in
                scanning = false
                requestText = code
            }
            .ignoresSafeArea()
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            switch c {
            case .freeze:
                Button("Freeze this wallet", role: .destructive) {
                    act("Frozen. Nothing can leave except a sweep to your recovery address.") { try await app.freezeVault() }
                }
            case .sweep(let to):
                Button("Sweep everything") {
                    act("Everything is on its way to your recovery address.") { _ = try await app.sweepVault(to: to) }
                }
            case .off:
                Button("Turn it off", role: .destructive) {
                    act("Turning the vault off waits out your delay. Cancel it here if it wasn't you.") { try await app.turnVaultOff() }
                }
            case .freezeOther(let owner):
                Button("Freeze it", role: .destructive) {
                    act("Frozen.") { try await app.freezeVault(owner: owner) }
                }
            }
        } message: { c in
            switch c {
            case .freeze: Text("Nothing can leave this wallet except a sweep to your recovery address. Unfreezing waits out your delay.")
            case .sweep(let to): Text("Sends this wallet's whole balance to \(shortAddress(to)).")
            case .off: Text("The vault stays on until your delay is over, and you can cancel it until then.")
            case .freezeOther(let owner): Text("\(shortAddress(owner)) can't send anything until it's unfrozen. Do this when it looks stolen.")
            }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .freeze: return "Freeze this wallet?"
        case .sweep: return "Sweep to your recovery address?"
        case .off: return "Turn the vault off?"
        case .freezeOther: return "Freeze this wallet?"
        case nil: return ""
        }
    }

    // MARK: Cards

    private var intro: some View {
        GlassCard {
            shield(color: Brand.lime, symbol: "lock.shield.fill")
            Text("Protect this wallet")
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(Brand.text)
            feature("hourglass", "Sends above your daily limit wait", "You get time to cancel anything you didn't start.")
            feature("iphone.and.arrow.forward", "A second key skips the wait", "Approve a large send from your other device.")
            feature("snowflake", "Freeze in one tap", "Then sweep everything to a recovery wallet you keep elsewhere.")
            feature("person.2.fill", "Guardians", "Friends who can freeze or cancel for you if your key is stolen.")
        }
    }

    private func hero(_ v: Vault.View) -> some View {
        let tint = v.frozen ? Brand.sky : Brand.lime
        let limit = v.settings.limit
        let used = limit == 0 ? 1 : min(1, Double(v.spentToday) / Double(limit))
        return GlassCard {
            HStack(alignment: .center, spacing: 14) {
                shield(color: tint, symbol: v.frozen ? "snowflake" : "lock.shield.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.frozen ? "Frozen" : "Protected")
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                        .foregroundStyle(Brand.text)
                    Text(v.frozen ? "Only a sweep to your recovery address can leave" : "Sends above your limit wait \(hours(v.settings.delay))")
                        .font(.footnote).foregroundStyle(Brand.muted)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Left today").font(.footnote).foregroundStyle(Brand.muted)
                    Spacer()
                    Text("\(Amount.format(v.leftToday)) of \(Amount.format(limit)) EGOC")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(Brand.text)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Brand.glow).frame(width: geo.size.width * (1 - used))
                    }
                }
                .frame(height: 8)
                if limit == 0 {
                    Text("Your limit is 0, so every send waits or needs your second key.")
                        .font(.caption).foregroundStyle(Brand.muted)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(label: "Delay", value: hours(v.settings.delay), icon: "hourglass")
                StatTile(label: "Above \(v.settings.highLimit > 0 ? Amount.format(v.settings.highLimit) : "–")",
                         value: v.settings.highLimit > 0 ? hours(v.settings.highDelay) : "Not set", icon: "hourglass.badge.plus")
                StatTile(label: "Second key", value: v.settings.secondKey.isEmpty ? "None" : shortAddress(v.settings.secondKey), icon: "key.fill")
                StatTile(label: "Recovery", value: v.settings.recovery.isEmpty ? "None" : shortAddress(v.settings.recovery), icon: "arrow.uturn.down")
                StatTile(label: "Guardians", value: "\(v.settings.guardians.count)", icon: "person.2.fill")
                StatTile(label: "Waiting sends", value: "\(v.queue.count)", icon: "tray.full.fill")
            }
        }
    }

    private func emergency(_ v: Vault.View) -> some View {
        GlassCard {
            SectionLabel(text: "If your key is stolen")
            if v.frozen {
                Button { act("Unfreezing waits out your delay.") { try await app.unfreezeVault() } } label: {
                    Label("Unfreeze", systemImage: "sun.max.fill")
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(busy || v.pending?.kind == "unfreeze")
            } else {
                Button { confirm = .freeze } label: { Label("Freeze this wallet", systemImage: "snowflake") }
                    .buttonStyle(OutlineButtonStyle(tint: Brand.danger))
                    .disabled(busy)
            }
            if !v.settings.recovery.isEmpty {
                Button { confirm = .sweep(v.settings.recovery) } label: {
                    Label("Sweep all to \(shortAddress(v.settings.recovery))", systemImage: "arrow.uturn.down.circle.fill")
                }
                .buttonStyle(OutlineButtonStyle(tint: Brand.sky))
                .disabled(busy)
            } else {
                Text("Add a recovery address in settings so you can sweep everything to safety.")
                    .font(.caption).foregroundStyle(Brand.muted)
            }
        }
    }

    private func pendingCard(_ pending: Vault.PendingChange) -> some View {
        GlassCard(tint: Brand.warning) {
            Label("\(pendingText(pending.kind)) on \(date(pending.at))", systemImage: "exclamationmark.triangle.fill")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Brand.warning)
            Text("If you didn't ask for this, cancel it now. Someone may have your key.")
                .font(.footnote).foregroundStyle(Brand.text)
            Button("Cancel this change") {
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
                    Image(systemName: ready ? "paperplane.fill" : "hourglass")
                        .foregroundStyle(mine ? Brand.lime : Brand.warning)
                        .frame(width: 34, height: 34)
                        .background((mine ? Brand.lime : Brand.warning).opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Amount.format(q.amount)) EGOC → \(shortAddress(q.to))")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Brand.text)
                        Text(ready ? "Ready, going out" : "Goes out \(date(q.at))").font(.caption).foregroundStyle(Brand.muted)
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

    private func settingsCard(_ current: Vault.Settings?) -> some View {
        GlassCard {
            HStack {
                SectionLabel(text: current == nil ? "Turn on the vault" : "Change the vault")
                Spacer()
                if current != nil {
                    Button { withAnimation(.snappy) { editing = false } } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.muted)
                    }
                    .accessibilityLabel("Close settings")
                }
            }
            VaultSettingsForm(initial: current, owner: app.address) { settings in
                await run("Saved. Stricter settings apply in the next block; looser ones wait out your delay.") {
                    try await app.saveVault(settings)
                    editing = false
                }
            }
        }
    }

    private func helped(_ v: Vault.View) -> some View {
        GlassCard(tint: v.frozen ? Brand.sky : nil) {
            HStack {
                Image(systemName: v.frozen ? "snowflake" : "lock.shield")
                    .foregroundStyle(v.frozen ? Brand.sky : Brand.lime)
                Text(shortAddress(v.owner)).font(.system(.subheadline, design: .monospaced).weight(.semibold)).foregroundStyle(Brand.text)
                Spacer()
                Text(v.frozen ? "Frozen" : "Protected").font(.caption.weight(.semibold)).foregroundStyle(v.frozen ? Brand.sky : Brand.muted)
            }
            if let pending = v.pending {
                Text("\(pendingText(pending.kind)) on \(date(pending.at))").font(.caption).foregroundStyle(Brand.warning)
                Button("Cancel the change") {
                    act("Cancelled.") { try await app.cancelInVault(owner: v.owner, target: Vault.cancelChange) }
                }
                .buttonStyle(OutlineButtonStyle(tint: Brand.danger)).disabled(busy)
            }
            ForEach(v.queue) { q in
                HStack {
                    Text("\(Amount.format(q.amount)) EGOC → \(shortAddress(q.to)), \(date(q.at))").font(.caption).foregroundStyle(Brand.text)
                    Spacer()
                    Button("Cancel") {
                        act("Cancelled.") { try await app.cancelInVault(owner: v.owner, target: q.id) }
                    }
                    .font(.caption.weight(.bold)).foregroundStyle(Brand.danger).disabled(busy)
                }
            }
            if !v.frozen {
                Button { confirm = .freezeOther(v.owner) } label: { Label("Freeze this wallet", systemImage: "snowflake") }
                    .buttonStyle(OutlineButtonStyle(tint: Brand.danger)).disabled(busy)
            }
        }
    }

    private var approveCard: some View {
        GlassCard {
            SectionLabel(text: "Approve as a second key")
            Text("If this iPhone is the second key of a wallet on Ego Desktop, open Wallet vault there, start a large send, and scan the code it shows.")
                .font(.footnote).foregroundStyle(Brand.muted)
            Button { scanning = true } label: { Label("Scan the request", systemImage: "qrcode.viewfinder") }
                .buttonStyle(OutlineButtonStyle())
            TextField("Or paste egovault1:…", text: $requestText, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .glassInput()
                .onChange(of: requestText) { _, text in read(text) }
            if let request {
                NoteCard(text: "\(shortAddress(request.from)) wants to \(request.action). Approve only if you started this yourself.",
                         icon: "exclamationmark.shield.fill", tint: Brand.warning)
                if approval == nil {
                    Button("Approve") { Task { await approve(request) } }
                        .buttonStyle(GlowButtonStyle())
                        .disabled(busy)
                }
            }
            if let approval {
                if let image = QRCode.image(for: approval) {
                    Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                        .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: 240).frame(maxWidth: .infinity)
                }
                Text("Show this to Ego Desktop, or copy it there.").font(.caption).foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity)
                Button("Copy approval") { UIPasteboard.general.string = approval }.buttonStyle(GhostButtonStyle())
            }
        }
    }

    private func shield(color: Color, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(Brand.ink)
            .frame(width: 52, height: 52)
            .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: color.opacity(0.45), radius: 12, y: 4)
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Brand.lime).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Brand.text)
                Text(detail).font(.caption).foregroundStyle(Brand.muted)
            }
        }
    }

    // MARK: Helpers

    private func hours(_ secs: Int64) -> String {
        let h = secs / 3600
        return h >= 48 && h % 24 == 0 ? "\(h / 24) days" : "\(h) h"
    }

    private func date(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .shortened)
    }

    private func pendingText(_ kind: String) -> String {
        switch kind {
        case "off": return "Vault turns off"
        case "unfreeze": return "Wallet unfreezes"
        default: return "Looser settings start"
        }
    }

    private func read(_ text: String) {
        approval = nil
        request = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            request = try Vault.ApprovalRequest.decode(text)
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
    }

    private func approve(_ request: Vault.ApprovalRequest) async {
        busy = true
        defer { busy = false }
        do {
            approval = try await app.approveVaultRequest(request)
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
    }

    private func load() async {
        do {
            let s = try await app.vaultStatus()
            status = s
            if s.vault != nil || !s.helping.isEmpty { app.askForAlerts() }
            problem = nil
            if await app.sendDueVaultSends(s) > 0 {
                note = "A waiting send's delay is over, so it went out."
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

/// The vault settings, in EGOC and hours.
struct VaultSettingsForm: View {
    let initial: Vault.Settings?
    let owner: String
    let save: (Vault.Settings) async -> Void
    @State private var limit = "100"
    @State private var delayHours = "24"
    @State private var highLimit = ""
    @State private var highDelayHours = ""
    @State private var recovery = ""
    @State private var secondKey = ""
    @State private var guardians = ""
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                field("Daily limit", "EGOC", text: $limit, keyboard: .decimalPad)
                field("Delay above it", "hours", text: $delayHours, keyboard: .numberPad)
            }
            HStack(spacing: 10) {
                field("Higher limit", "optional", text: $highLimit, keyboard: .decimalPad)
                field("Its delay", "hours", text: $highDelayHours, keyboard: .numberPad)
            }
            address("Recovery address", "A wallet you keep somewhere else", text: $recovery)
            address("Second key", "Your other device's wallet address", text: $secondKey)
            VStack(alignment: .leading, spacing: 6) {
                label("Guardians")
                TextField("One address per line", text: $guardians, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .lineLimit(2...5)
                    .glassInput()
            }
            if let problem { ProblemBanner(text: problem) }
            Button(saving ? "Saving…" : initial == nil ? "Turn on the vault" : "Save settings") {
                Task { await submit() }
            }
            .buttonStyle(GlowButtonStyle())
            .disabled(saving)
        }
        .onAppear(perform: fill)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(Brand.muted)
    }

    private func field(_ title: String, _ hint: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            TextField(hint, text: text).keyboardType(keyboard).glassInput()
        }
        .frame(maxWidth: .infinity)
    }

    private func address(_ title: String, _ hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            TextField(hint, text: text)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .glassInput()
        }
    }

    private func fill() {
        guard let s = initial else { return }
        limit = Amount.format(s.limit).replacingOccurrences(of: ",", with: "")
        delayHours = "\(s.delay / 3600)"
        highLimit = s.highLimit > 0 ? Amount.format(s.highLimit).replacingOccurrences(of: ",", with: "") : ""
        highDelayHours = s.highDelay > 0 ? "\(s.highDelay / 3600)" : ""
        recovery = s.recovery
        secondKey = s.secondKey
        guardians = s.guardians.joined(separator: "\n")
    }

    private func submit() async {
        guard let l = Amount.parse(limit), let d = Int64(delayHours.trimmingCharacters(in: .whitespaces)) else {
            problem = "Enter a limit and a delay in hours."
            return
        }
        let hl = highLimit.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : (Amount.parse(highLimit) ?? 0)
        let hd = hl > 0 ? (Int64(highDelayHours.trimmingCharacters(in: .whitespaces)) ?? 0) : 0
        let list = guardians.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).map(String.init)
        let addresses = [recovery, secondKey].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } + list
        if let bad = addresses.first(where: { !$0.isEmpty && !EgoAddress.isValid($0) }) {
            problem = "\(bad) isn't an Ego address."
            return
        }
        if d < 1 || d > 720 || (hl > 0 && (hl <= l || hd <= d || hd > 720)) {
            problem = "The delay is 1 to 720 hours, and the higher limit and its delay must both be above the first ones."
            return
        }
        problem = nil
        saving = true
        await save(Vault.Settings(limit: l, delay: d * 3600, highLimit: hl, highDelay: hd * 3600,
                                  recovery: recovery.trimmingCharacters(in: .whitespacesAndNewlines),
                                  secondKey: secondKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                  guardians: list))
        saving = false
    }
}
