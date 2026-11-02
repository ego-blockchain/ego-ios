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
        GlassPage {
            PageTitle("Theft holds", subtitle: "Stop stolen EGOC where it went")
            if let note { NoteCard(text: note, icon: "checkmark.circle.fill", tint: Brand.mint) }
            if let problem { ProblemBanner(text: problem) }
            GlassCard {
                step("exclamationmark.shield.fill", "A victim asks for a hold", "on the addresses the stolen EGOC went to.")
                step("checkmark.seal.fill", "Staked holders and nodes vote", "to confirm it. A held address can appeal.")
                step("arrow.uturn.backward.circle.fill", "The victim asks for it back", "and a second vote returns the funds.")
            }
            if let status {
                if !status.active {
                    NoteCard(text: "Theft holds aren't switched on in the network yet. They start after the security audit.",
                             icon: "clock.fill", tint: Brand.warning)
                }
                if status.myLocked > 0 {
                    NoteCard(text: "\(Amount.format(status.myLocked)) EGOC of this wallet is held or bonded right now.",
                             icon: "lock.fill", tint: Brand.warning)
                }
                if status.holds.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.raised").font(.system(size: 30, weight: .semibold)).foregroundStyle(Brand.muted)
                        Text("No holds right now.").font(.subheadline).foregroundStyle(Brand.muted)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                ForEach(status.holds) { h in hold(h, stake: status.myStake, active: status.active) }
            } else if problem == nil {
                ProgressView().tint(Brand.lime).frame(maxWidth: .infinity).padding(.top, 30)
            }
        }
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

    private func step(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Brand.lime).frame(width: 22)
            (Text(title).fontWeight(.semibold).foregroundColor(Brand.text) + Text(" " + detail).foregroundColor(Brand.muted))
                .font(.footnote)
        }
    }

    private func phaseTint(_ phase: String) -> Color {
        switch phase {
        case "voting", "return_voting": return Brand.warning
        case "confirmed": return Brand.danger
        case "returned": return Brand.mint
        default: return Brand.muted
        }
    }

    private func hold(_ h: Holds.Hold, stake: UInt64, active: Bool) -> some View {
        GlassCard {
            HStack {
                Tag(text: phaseText(h.phase).capitalized, tint: phaseTint(h.phase))
                Spacer()
                Text("Victim \(shortAddress(h.victim))").font(.caption).foregroundStyle(Brand.muted)
            }
            Text(h.caseText).font(.subheadline).foregroundStyle(Brand.text)
            ForEach(h.held, id: \.self) { held in
                HStack {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(Brand.warning)
                    Text(shortAddress(held.address)).font(.system(.caption, design: .monospaced)).foregroundStyle(Brand.text)
                    Spacer()
                    Text("\(Amount.format(held.amount)) EGOC").font(.system(.caption, design: .rounded, weight: .bold)).foregroundStyle(Brand.text)
                }
            }
            if h.phase == "voting" || h.phase == "return_voting" {
                let t = h.phase == "voting" ? h.confirm : h.ret
                let total = max(Double(t.stakeYes + t.stakeNo), 1)
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            Capsule().fill(Brand.lime).frame(width: geo.size.width * Double(t.stakeYes) / total)
                            Capsule().fill(Brand.danger.opacity(0.8))
                        }
                    }
                    .frame(height: 8)
                    HStack {
                        Text("\(Amount.format(t.stakeYes)) yes").foregroundStyle(Brand.lime)
                        Text("\(Amount.format(t.stakeNo)) no").foregroundStyle(Brand.danger)
                        Spacer()
                        Text("Ends \(date(h.phase == "voting" ? h.voteEnds : h.returnEnds))").foregroundStyle(Brand.muted)
                    }
                    .font(.caption)
                }
            }
            ForEach(h.appeals, id: \.self) { a in
                NoteCard(text: "Appeal from \(shortAddress(a.address)): \(a.text)", icon: "text.bubble.fill", tint: Brand.warning)
            }
            if active, let phase = h.openVote {
                if stake == 0 {
                    Text("Stake EGOC to vote on holds.").font(.caption).foregroundStyle(Brand.muted)
                } else {
                    HStack(spacing: 10) {
                        Button(phase == Holds.phaseConfirm ? "Hold it" : "Return it") {
                            Task { await run("Voted. Your stake stays locked until the vote ends.") { try await app.voteOnHold(h, phase: phase, yes: true) } }
                        }
                        .buttonStyle(OutlineButtonStyle())
                        Button(phase == Holds.phaseConfirm ? "Release it" : "Don't return") {
                            Task { await run("Voted. Your stake stays locked until the vote ends.") { try await app.voteOnHold(h, phase: phase, yes: false) } }
                        }
                        .buttonStyle(OutlineButtonStyle(tint: Brand.danger))
                    }
                    .disabled(busy)
                }
            }
            if active, h.canAppeal(app.address) {
                Button("Appeal: these funds aren't stolen") { appealText = ""; appealing = h }
                    .buttonStyle(OutlineButtonStyle(tint: Brand.warning)).disabled(busy)
            }
            if active, h.canOpenReturn(app.address) {
                Button("Ask for the funds back") {
                    Task { await run("Return vote opened.") { try await app.openReturnVote(h) } }
                }
                .buttonStyle(GlowButtonStyle()).disabled(busy)
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
