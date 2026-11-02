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
        Form {
            PageTitle("Staking")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            Section {
                Text("Staked EGOC helps secure the Ego test network and gives your DAO votes their weight. It stays locked for the period you choose; leaving early costs 10% of the stake.")
                    .font(.footnote)
                    .foregroundStyle(Brand.muted)
            }
            if let status {
                if status.staked > 0 {
                    current(status)
                }
                Section(status.staked > 0 ? "Stake more" : "Stake") {
                    TextField("Amount (EGOC)", text: $amount).keyboardType(.decimalPad)
                    Picker("Lock", selection: $lockDays) {
                        ForEach(status.lockOptions, id: \.days) { o in
                            Text("\(o.days) days · \(rate(o.apr))").tag(o.days)
                        }
                    }
                    if status.staked > 0 {
                        Text("Adding to a stake starts its lock and its reward again from today, so the \(Amount.format(status.accrued)) EGOC reward so far is not paid. Unstake first to collect it.")
                            .font(.caption).foregroundStyle(Brand.warning)
                    }
                    Button(busy ? "Staking…" : "Stake") { Task { await stake() } }
                        .disabled(busy || Amount.parse(amount) == nil)
                }
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

    @ViewBuilder
    private func current(_ s: Staking.Status) -> some View {
        Section("Your stake") {
            row("Staked", "\(Amount.format(s.staked)) EGOC")
            row("Rate", rate(s.apr))
            row("Reward so far", "\(Amount.format(s.accrued)) EGOC")
            row("Locked until", s.locked ? date(s.unlockAt) : "Unlocked")
            row("Share of all stake", s.share.formatted(.percent.precision(.fractionLength(0...2))))
            if s.voteLockedUntil > Int64(Date().timeIntervalSince1970) {
                Text("A DAO vote or report keeps this stake in place until \(date(s.voteLockedUntil)).")
                    .font(.caption).foregroundStyle(Brand.warning)
            }
            Button("Unstake everything", role: .destructive) { confirmingUnstake = true }
                .disabled(busy || !s.canUnstake)
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
