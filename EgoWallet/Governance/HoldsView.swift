import EgoKit
import SwiftUI

struct HoldsPage: Hashable {}

extension AppModel {
    func holdsStatus() async throws -> Holds.Status {
        let address = self.address
        return try await perform { try await $0.holdsStatus(of: address) }
    }

    private func holdOperation<T: Encodable>(_ txType: String, _ body: T) async throws {
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try Holds.operation(key: key, txType: txType, body: body, nonce: info.next, fee: info.feeUegoc,
                                     version: max(3, info.txVersion))
        _ = try await submit(tx)
    }

    func voteOnHold(_ hold: Holds.Hold, phase: String, yes: Bool) async throws {
        try await holdOperation(Holds.vote, Holds.VoteBody(id: hold.id, phase: phase, yes: yes))
    }

    func appealHold(_ hold: Holds.Hold, text: String) async throws {
        try await holdOperation(Holds.appeal, Holds.AppealBody(id: hold.id, text: text))
    }

    func openReturnVote(_ hold: Holds.Hold) async throws {
        try await holdOperation(Holds.openReturn, Holds.IdBody(id: hold.id))
    }
}

/// Theft holds: what the network is holding, voting with your stake, appealing a
/// hold on your own funds, and asking for the funds back as the victim.
struct HoldsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var status: Holds.Status?
    @State private var appealing: Holds.Hold?
    @State private var appealText = ""
    @State private var problem: String?
    @State private var note: String?
    @State private var busy = false

    var body: some View {
        Form {
            PageTitle("Theft holds")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            Section {
                Text("When someone's EGOC is stolen, they can ask the network to hold it where it went. Staked holders and nodes vote on each hold; a held address can appeal, and once a hold is confirmed the victim can ask for the funds back.")
                    .font(.footnote)
                    .foregroundStyle(Brand.muted)
            }
            if let status {
                if !status.active {
                    Section { Text("Theft holds aren't switched on in the network yet. They start after the security audit.").font(.footnote) }
                }
                if status.myLocked > 0 {
                    Section { Text("\(Amount.format(status.myLocked)) EGOC of this wallet is held or bonded right now.").font(.footnote).foregroundStyle(Brand.warning) }
                }
                if status.holds.isEmpty {
                    Section { Text("No holds right now.").font(.footnote).foregroundStyle(Brand.muted) }
                }
                ForEach(status.holds) { h in hold(h, stake: status.myStake, active: status.active) }
            } else if problem == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
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
        .alert("Appeal this hold", isPresented: Binding(get: { appealing != nil }, set: { if !$0 { appealing = nil } })) {
            TextField("Why your funds aren't stolen", text: $appealText)
            Button("Send appeal") {
                if let h = appealing {
                    let text = appealText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await run("Appeal sent. Voters see it next to the hold.") { try await app.appealHold(h, text: text) } }
                }
                appealing = nil
            }
            Button("Cancel", role: .cancel) { appealing = nil }
        } message: {
            Text("You can appeal once, in up to \(Holds.maxAppealBytes) characters.")
        }
    }

    @ViewBuilder
    private func hold(_ h: Holds.Hold, stake: UInt64, active: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(h.caseText).font(.footnote)
                Text("Victim \(shortAddress(h.victim)) · \(phaseText(h.phase))").font(.caption).foregroundStyle(Brand.muted)
                ForEach(h.held, id: \.self) { held in
                    Text("Holds \(Amount.format(held.amount)) EGOC at \(shortAddress(held.address))").font(.caption)
                }
                if h.phase == "voting" || h.phase == "return_voting" {
                    let t = h.phase == "voting" ? h.confirm : h.ret
                    Text("Stake: \(Amount.format(t.stakeYes)) yes, \(Amount.format(t.stakeNo)) no · ends \(date(h.phase == "voting" ? h.voteEnds : h.returnEnds))")
                        .font(.caption).foregroundStyle(Brand.muted)
                }
            }
            ForEach(h.appeals, id: \.self) { a in
                Text("Appeal from \(shortAddress(a.address)): \(a.text)").font(.caption).foregroundStyle(Brand.warning)
            }
            if active, let phase = h.openVote {
                if stake == 0 {
                    Text("Stake EGOC to vote on holds.").font(.caption).foregroundStyle(Brand.muted)
                } else {
                    HStack {
                        Button(phase == Holds.phaseConfirm ? "Hold it" : "Return it") {
                            Task { await run("Voted. Your stake stays locked until the vote ends.") { try await app.voteOnHold(h, phase: phase, yes: true) } }
                        }
                        Spacer()
                        Button(phase == Holds.phaseConfirm ? "Release it" : "Don't return", role: .destructive) {
                            Task { await run("Voted. Your stake stays locked until the vote ends.") { try await app.voteOnHold(h, phase: phase, yes: false) } }
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                }
            }
            if active, h.canAppeal(app.address) {
                Button("Appeal: these funds aren't stolen") { appealText = ""; appealing = h }.disabled(busy)
            }
            if active, h.canOpenReturn(app.address) {
                Button("Ask for the funds back") {
                    Task { await run("Return vote opened.") { try await app.openReturnVote(h) } }
                }
                .disabled(busy)
            }
        }
    }

    private func phaseText(_ phase: String) -> String {
        switch phase {
        case "signing": return "being placed"
        case "voting": return "vote open"
        case "confirmed": return "confirmed"
        case "return_voting": return "return vote open"
        case "returned": return "returned to the victim"
        case "rejected", "failed": return "released"
        default: return phase.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func date(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .shortened)
    }

    private func load() async {
        do {
            status = try await app.holdsStatus()
            problem = nil
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
            problem = app.message(for: error)
        }
    }
}
