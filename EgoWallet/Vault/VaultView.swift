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

    var body: some View {
        Form {
            PageTitle("Wallet vault")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            Section {
                Text("Sends above your daily limit wait, so you can cancel them, or need your second key. Someone who copies your key can't switch the vault off or change it without waiting out the delay.")
                    .font(.footnote)
                    .foregroundStyle(Brand.muted)
            }
            if let status, !status.active {
                Section {
                    Text("The vault isn't switched on in the network yet. It starts once the Ego nodes run version 0.3.673.")
                        .font(.footnote)
                }
            }
            if let vault = status?.vault, !editing {
                ownVault(vault)
            }
            if let status, status.active, status.vault == nil || editing {
                Section(status.vault == nil ? "Turn on the vault" : "Change the vault") {
                    VaultSettingsForm(initial: status.vault?.settings, owner: app.address) { settings in
                        await run("Saved. Stricter settings apply in the next block; looser ones wait out your delay.") {
                            try await app.saveVault(settings)
                            editing = false
                        }
                    }
                }
            }
            if let status, status.active, status.vault != nil {
                Section {
                    Button(editing ? "Close settings" : "Change settings") { editing.toggle() }
                }
            }
            if let helping = status?.helping, !helping.isEmpty {
                Section("Vaults you protect") {
                    ForEach(helping) { v in helped(v) }
                }
            }
            Section("Approve a request") {
                Text("When this iPhone is the second key of a vault, scan the code Ego Desktop shows for a large send and approve it here.")
                    .font(.footnote)
                    .foregroundStyle(Brand.muted)
                Button { scanning = true } label: { Label("Scan the request", systemImage: "qrcode.viewfinder") }
                TextField("Or paste egovault1:…", text: $requestText, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: requestText) { _, text in read(text) }
                if let request {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(shortAddress(request.from)) wants to \(request.action).")
                            .font(.footnote.weight(.semibold))
                        Text("Approve only if you started this yourself.").font(.caption).foregroundStyle(Brand.warning)
                    }
                    if approval == nil {
                        Button("Approve") { Task { await approve(request) } }.disabled(busy)
                    }
                }
                if let approval {
                    if let image = QRCode.image(for: approval) {
                        Image(uiImage: image).resizable().interpolation(.none).scaledToFit().frame(maxWidth: 240).frame(maxWidth: .infinity)
                    }
                    Text("Show this to Ego Desktop, or copy it there.").font(.caption).foregroundStyle(Brand.muted)
                    Button("Copy approval") { UIPasteboard.general.string = approval }
                }
            }
            if let note {
                Section { Text(note).font(.footnote) }
            }
            if let problem {
                Section { Text(problem).font(.footnote).foregroundStyle(Brand.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $scanning) {
            QRScanner { code in
                scanning = false
                requestText = code
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func ownVault(_ v: Vault.View) -> some View {
        Section("Your vault") {
            row("Status", v.frozen ? "Frozen" : "On")
            row("Left today", "\(Amount.format(v.leftToday)) EGOC")
            row("Delay", hours(v.settings.delay) + (v.settings.highLimit > 0 ? ", \(hours(v.settings.highDelay)) above \(Amount.format(v.settings.highLimit)) EGOC" : ""))
            row("Recovery", v.settings.recovery.isEmpty ? "None" : shortAddress(v.settings.recovery))
            row("Second key", v.settings.secondKey.isEmpty ? "None" : shortAddress(v.settings.secondKey))
            row("Guardians", "\(v.settings.guardians.count)")
        }
        if let pending = v.pending {
            Section("Waiting change") {
                Text("\(pendingText(pending.kind)) lands \(date(pending.at)). Cancel it if you didn't ask for it.")
                    .font(.footnote)
                Button("Cancel this change", role: .destructive) {
                    Task { await run("Cancelled.") { try await app.cancelInVault(target: Vault.cancelChange) } }
                }.disabled(busy)
            }
        }
        if !v.queue.isEmpty {
            Section("Waiting sends") {
                ForEach(v.queue) { q in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Amount.format(q.amount)) EGOC → \(shortAddress(q.to))").font(.footnote.weight(.semibold))
                        Text(Double(q.at) <= Date().timeIntervalSince1970 ? "Ready, going out" : "Goes out \(date(q.at))")
                            .font(.caption).foregroundStyle(Brand.muted)
                        if !app.vaultMine.contains(q.id) {
                            Text("Not started on this iPhone").font(.caption).foregroundStyle(Brand.warning)
                        }
                        Button("Cancel", role: .destructive) {
                            Task { await run("Cancelled.") { try await app.cancelInVault(target: q.id) } }
                        }.disabled(busy)
                    }
                }
            }
        }
        Section {
            if !v.frozen {
                Button("Freeze now", role: .destructive) {
                    Task { await run("Frozen. Nothing can leave except a sweep to your recovery address.") { try await app.freezeVault() } }
                }.disabled(busy)
            }
            if !v.settings.recovery.isEmpty {
                Button("Sweep all to recovery") {
                    Task { await run("Everything is on its way to your recovery address.") { _ = try await app.sweepVault(to: v.settings.recovery) } }
                }.disabled(busy)
            }
            if v.frozen {
                Button("Unfreeze") {
                    Task { await run("Unfreezing waits out your delay.") { try await app.unfreezeVault() } }
                }.disabled(busy)
            }
            Button("Turn the vault off") {
                Task { await run("Turning the vault off waits out your delay. Cancel it here if it wasn't you.") { try await app.turnVaultOff() } }
            }.disabled(busy)
        }
    }

    @ViewBuilder
    private func helped(_ v: Vault.View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shortAddress(v.owner)).font(.system(.footnote, design: .monospaced).weight(.semibold))
            Text(v.frozen ? "Frozen" : "Protected").font(.caption).foregroundStyle(v.frozen ? Brand.danger : Brand.muted)
            if let pending = v.pending {
                Text("Waiting change: \(pendingText(pending.kind)), lands \(date(pending.at))").font(.caption).foregroundStyle(Brand.warning)
                Button("Cancel the change", role: .destructive) {
                    Task { await run("Cancelled.") { try await app.cancelInVault(owner: v.owner, target: Vault.cancelChange) } }
                }.disabled(busy)
            }
            ForEach(v.queue) { q in
                Text("\(Amount.format(q.amount)) EGOC → \(shortAddress(q.to)), goes out \(date(q.at))").font(.caption)
                Button("Cancel this send", role: .destructive) {
                    Task { await run("Cancelled.") { try await app.cancelInVault(owner: v.owner, target: q.id) } }
                }.disabled(busy)
            }
            if !v.frozen {
                Button("Freeze this wallet", role: .destructive) {
                    Task { await run("Frozen.") { try await app.freezeVault(owner: v.owner) } }
                }.disabled(busy)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Brand.muted)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private func hours(_ secs: Int64) -> String { "\(secs / 3600) h" }

    private func date(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .shortened)
    }

    private func pendingText(_ kind: String) -> String {
        switch kind {
        case "off": return "Turning the vault off"
        case "unfreeze": return "Unfreezing"
        default: return "New, looser settings"
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
            problem = nil
            if await app.sendDueVaultSends(s) > 0 {
                note = "A waiting send's delay is over, so it went out."
            }
        } catch {
            problem = app.message(for: error)
        }
    }

    private func run(_ success: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            note = success
            problem = nil
            await load()
        } catch {
            problem = Vault.readable(error)
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
        Group {
            TextField("Daily limit without approval (EGOC)", text: $limit).keyboardType(.decimalPad)
            TextField("Delay above it (hours)", text: $delayHours).keyboardType(.numberPad)
            TextField("Higher limit (EGOC, optional)", text: $highLimit).keyboardType(.decimalPad)
            TextField("Delay above the higher limit (hours)", text: $highDelayHours).keyboardType(.numberPad)
            TextField("Recovery address (a wallet you keep elsewhere)", text: $recovery)
                .font(.system(.footnote, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Second key: address of your other device's wallet", text: $secondKey)
                .font(.system(.footnote, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Guardians, one address per line", text: $guardians, axis: .vertical)
                .font(.system(.footnote, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            if let problem { Text(problem).font(.caption).foregroundStyle(Brand.danger) }
            Button(saving ? "Saving…" : initial == nil ? "Turn on the vault" : "Save vault settings") {
                Task { await submit() }
            }
            .disabled(saving)
        }
        .onAppear(perform: fill)
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
