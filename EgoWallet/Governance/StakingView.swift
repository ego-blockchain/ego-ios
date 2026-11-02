import EgoKit
import SwiftUI

/// Staking: lock EGOC to help secure the network and to vote in the DAO. The reward
/// rate and the unstake rules are the chain's; this page only shows and signs them.
struct StakingView: View {
    @EnvironmentObject private var app: AppModel
    @State private var status: Staking.Status?
    @State private var amount = ""
    @State private var lockDays: UInt32 = 90
    @State private var problem: String?
    @State private var note: String?
    @State private var busy = false
    @State private var confirmingUnstake = false

    var body: some View {
        GlassPage {
            PageTitle("Staking", subtitle: "Help secure the network and vote in the DAO")
            if let note { NoteCard(text: note, icon: "checkmark.circle.fill", tint: Brand.mint) }
            if let problem { ProblemBanner(text: problem) }
            if let status {
                if status.staked > 0 { current(status) }
                stakeCard(status)
                NoteCard(text: "Staked EGOC stays locked for the period you choose on the Ego test network. Leaving early costs 10% of the stake.")
            } else if problem == nil {
                ProgressView().tint(Brand.lime).frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Unstake everything?", isPresented: $confirmingUnstake, titleVisibility: .visible) {
            if let status {
                Button(status.locked ? "Unstake and pay \(Amount.format(status.earlyFee)) EGOC" : "Unstake", role: .destructive) {
                    Task { await unstake(status) }
                }
            }
        } message: {
            if let status, status.locked {
                Text("Your lock runs until \(date(status.unlockAt)). Leaving now costs 10% of the stake.")
            }
        }
    }

    private func current(_ s: Staking.Status) -> some View {
        GlassCard {
            SectionLabel(text: "Your stake")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Amount.format(s.staked))
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundStyle(Brand.glow)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("EGOC").font(.system(.headline, design: .rounded)).foregroundStyle(Brand.muted)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(label: "Rate", value: rate(s.apr), icon: "chart.line.uptrend.xyaxis")
                StatTile(label: "Reward so far", value: "\(Amount.format(s.accrued)) EGOC", icon: "sparkles")
                StatTile(label: "Locked until", value: s.locked ? shortDate(s.unlockAt) : "Unlocked", icon: s.locked ? "lock.fill" : "lock.open.fill")
                StatTile(label: "Share of all", value: s.share.formatted(.percent.precision(.fractionLength(0...2))), icon: "chart.pie.fill")
            }
            if s.voteLockedUntil > Int64(Date().timeIntervalSince1970) {
                NoteCard(text: "A DAO vote or report keeps this stake in place until \(date(s.voteLockedUntil)).",
                         icon: "checkmark.seal.fill", tint: Brand.warning)
            }
            Button("Unstake everything") { confirmingUnstake = true }
                .buttonStyle(OutlineButtonStyle(tint: Brand.danger))
                .disabled(busy || !s.canUnstake)
        }
    }

    private func stakeCard(_ s: Staking.Status) -> some View {
        GlassCard {
            SectionLabel(text: s.staked > 0 ? "Stake more" : "Stake EGOC")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Amount").font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(Brand.muted)
                    Spacer()
                    Button("Max") {
                        // Leaves 1 EGOC for the fee, well above a normal one.
                        let balance = app.balance ?? 0
                        amount = Amount.format(balance > 1_000_000 ? balance - 1_000_000 : 0).replacingOccurrences(of: ",", with: "")
                    }
                    .font(.system(.caption, design: .rounded, weight: .bold)).foregroundStyle(Brand.lime)
                }
                HStack {
                    TextField("0", text: $amount).keyboardType(.decimalPad)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                    Text("EGOC").font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Brand.muted)
                }
                .glassInput()
                Text("Available: \(Amount.format(app.balance ?? 0)) EGOC").font(.caption).foregroundStyle(Brand.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Lock for").font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(Brand.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(s.lockOptions, id: \.days) { o in lockChip(o.days, o.apr) }
                }
            }
            if s.staked > 0 {
                NoteCard(text: "Adding to a stake starts its lock and its reward again from today, so the \(Amount.format(s.accrued)) EGOC reward so far is not paid. Unstake first to collect it.",
                         icon: "exclamationmark.triangle.fill", tint: Brand.warning)
            }
            Button(busy ? "Staking…" : "Stake") { Task { await stake() } }
                .buttonStyle(GlowButtonStyle())
                .disabled(busy || Amount.parse(amount) == nil)
        }
    }

    private func lockChip(_ days: UInt32, _ apr: Double) -> some View {
        let on = days == lockDays
        return Button {
            Haptics.tap()
            lockDays = days
        } label: {
            VStack(spacing: 2) {
                Text("\(days) days").font(.system(.subheadline, design: .rounded, weight: .bold))
                Text(rate(apr)).font(.caption2)
            }
            .foregroundStyle(on ? Brand.ink : Brand.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(on ? AnyShapeStyle(Brand.glow) : AnyShapeStyle(Color.white.opacity(0.05)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(on ? 0 : 0.1)))
        }
        .buttonStyle(.plain)
    }

    private func shortDate(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }

    private func rate(_ apr: Double) -> String { "\(apr.formatted(.number.precision(.fractionLength(0...2))))% a year" }

    private func date(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .shortened)
    }

    private func load() async {
        do {
            let s = try await app.stakingStatus()
            status = s
            if !s.lockOptions.contains(where: { $0.days == lockDays }), let first = s.lockOptions.first { lockDays = first.days }
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
    }

    private func stake() async {
        guard let value = Amount.parse(amount) else { return }
        await run("Staked. It counts once the next block includes it.") {
            try await app.stake(value, lockDays: lockDays)
            amount = ""
        }
    }

    private func unstake(_ s: Staking.Status) async {
        await run("Unstaked. Your EGOC and its reward come back once the next block includes it.") {
            try await app.unstake(s)
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
