import EgoKit
import SwiftUI

/// The same numbers as the Earnings page in Ego Desktop. The live rate and
/// breakdown come from the owner's own computer; the paid totals come from the
/// chain, so they show up through any gateway.
struct EarningsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var node: NodeEarnings?
    @State private var nodeNote: String?
    @State private var fetchedAt = Date()
    @State private var chain: RewardsSummary?
    @State private var chainProblem: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let node {
                    if let until = node.earnings.rewardSuspendedUntil, until > Int64(Date().timeIntervalSince1970) {
                        suspendedBanner(until: until)
                    }
                    counters(node)
                    summary(node)
                    breakdown(node.earnings)
                    status(node)
                } else if loaded {
                    nodeMissing
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.card()
                }
                paidOnChain
            }
            .padding(16)
        }
        .refreshable { await load() }
        .screenBackground()
        .navigationTitle("Earnings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        async let lookup = model.myNodeEarnings()
        async let paid: Result<RewardsSummary, Error> = {
            do { return .success(try await model.rewards()) } catch { return .failure(error) }
        }()
        switch await lookup {
        case .found(let found):
            node = found
            fetchedAt = Date()
            nodeNote = nil
        case .notFound:
            node = nil
            nodeNote = nil
        case .unreachable(let why):
            if node == nil { nodeNote = why }
        }
        switch await paid {
        case .success(let summary):
            chain = summary
            chainProblem = nil
        case .failure(let error):
            chainProblem = model.message(for: error)
        }
        loaded = true
    }

    // MARK: Desktop sections

    private func suspendedBanner(until: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rewards suspended: storage reduction penalty")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.danger)
            Text("Your computer reduced its storage allocation, so all rewards are paused for 14 days. They resume on \(Date(timeIntervalSince1970: TimeInterval(until)).formatted(date: .abbreviated, time: .omitted)).")
                .font(.caption)
                .foregroundStyle(Brand.danger.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.danger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func counters(_ node: NodeEarnings) -> some View {
        let e = node.earnings
        let offset = TimeInterval(node.now) - fetchedAt.timeIntervalSince1970
        return VStack(alignment: .leading, spacing: 16) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince1970 + offset - TimeInterval(e.sessionStarted))
                Counter(label: "This session",
                        value: Egoc.format(elapsed * Double(e.dailyRewards) / 86_400, digits: 6),
                        caption: "EGOC since app start",
                        color: Brand.mint)
            }
            Divider().overlay(Brand.line)
            HStack(alignment: .top) {
                Counter(label: "Per day", value: Egoc.format(Double(e.dailyRewards), digits: 4),
                        caption: "EGOC / 24h at current rate", color: .cyan)
                Spacer()
                Counter(label: "All time", value: Egoc.format(Double(e.totalEarned), digits: 4),
                        caption: "EGOC settled, all sessions", color: .indigo)
            }
            Text("Session accrual is a live projection from your current rate. All time reflects rewards settled on chain and persists across restarts.")
                .font(.caption2)
                .foregroundStyle(Brand.muted)
        }
        .card()
    }

    private func summary(_ node: NodeEarnings) -> some View {
        let e = node.earnings
        let offset = TimeInterval(node.now) - fetchedAt.timeIntervalSince1970
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            Tile(label: "Settlement rate", value: Egoc.format(Double(e.dailyRewards), digits: 4), unit: "EGOC / 24H", color: Brand.mint)
            Tile(label: "Epoch target", value: Egoc.format(Double(e.epochRewards), digits: 4), unit: "EGOC / 7D", color: .cyan)
            Tile(label: "Pending payout", value: Egoc.format(Double(e.pendingRewards), digits: 4), unit: "UEGOC UNCONFIRMED", color: Brand.warning)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let uptime = max(0, Int64(context.date.timeIntervalSince1970 + offset) - e.sessionStarted)
                Tile(label: "Uptime this session", value: Egoc.duration(uptime), unit: "NODE ACTIVE", color: .indigo)
            }
        }
    }

    private func breakdown(_ e: EarningsData) -> some View {
        let b = e.rewardBreakdown
        let total = max(1, b.storageRewards + b.consensusRewards + b.coverageRewards + b.retrievalRewards)
        let rows: [(String, UInt64, Color, String)] = [
            ("Storage", b.storageRewards, .blue, "~$0.002/GB/day, paid in EGOC"),
            ("Consensus", b.consensusRewards, .purple, "~$0.20/day, paid in EGOC"),
            ("Coverage", b.coverageRewards, .green, e.coverageOnline ? "~$0.15/day, paid in EGOC" : "Offline: criteria not met"),
            ("Retrieval", b.retrievalRewards, .orange, "~$0.003/GB served, paid in EGOC"),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Potential reward breakdown").font(.headline).foregroundStyle(Brand.text)
                Text("Maximum rates at the current price. Amounts change as the EGOC price moves or the node pool depletes.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
            ForEach(rows, id: \.0) { label, value, color, desc in
                let pct = Int((Double(value) / Double(total) * 100).rounded())
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(label).font(.subheadline.weight(.medium)).foregroundStyle(Brand.text)
                        Spacer()
                        Text(Egoc.format(Double(value), digits: 2)).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                        Text("\(pct)%").font(.caption).foregroundStyle(Brand.muted)
                    }
                    Text(desc).font(.caption2).foregroundStyle(Brand.muted)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Brand.raised)
                            Capsule().fill(color).frame(width: geo.size.width * CGFloat(pct) / 100)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .card()
    }

    private func status(_ node: NodeEarnings) -> some View {
        let gb = Double(node.storageAllocatedBytes) / 1e9
        let offset = TimeInterval(node.now) - fetchedAt.timeIntervalSince1970
        return VStack(alignment: .leading, spacing: 12) {
            Text("Node status").font(.headline).foregroundStyle(Brand.text)
            StatusRow(label: "App / Node", value: "Running", color: Brand.mint)
            StatusRow(label: "Coverage beacon",
                      value: node.earnings.coverageOnline ? "Online" : "Offline",
                      color: node.earnings.coverageOnline ? Brand.mint : Brand.danger)
            StatusRow(label: "Storage",
                      value: gb > 0 ? String(format: "%.1f GB active", gb) : "Not configured",
                      color: gb > 0 ? Brand.mint : Brand.warning)
            StatusRow(label: "Compute sharing",
                      value: node.computeEnabled ? "Active" : "Off",
                      color: node.computeEnabled ? .purple : Brand.muted)
            if let compute = node.compute, compute.last24hUegoc > 0 {
                StatusRow(label: "Compute earned (24h)", value: "\(Egoc.format(Double(compute.last24hUegoc), digits: 4)) EGOC", color: .purple)
            }
            StatusRow(label: "DRS score (testnet)",
                      value: String(format: "%.2f", node.drsScore),
                      color: node.drsScore > 0 ? Brand.mint : Brand.muted)
            StatusRow(label: "Validator", value: node.isValidator ? "Yes" : "No", color: Brand.text)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let uptime = max(0, Int64(context.date.timeIntervalSince1970 + offset) - node.earnings.sessionStarted)
                StatusRow(label: "Session uptime", value: Egoc.duration(uptime), color: Brand.text)
            }
            Text("From \(shortAddress(node.address)) · updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(Brand.muted)
        }
        .card()
    }

    // MARK: When the computer can't be asked

    private var nodeMissing: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Your computer")
            Text(nodeNote == nil
                 ? "No Ego Desktop using this wallet is serving phones right now."
                 : "Your Ego Desktop didn't answer.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.text)
            Text(nodeNote.map { "\($0)\n\n" } ?? "")
                + Text("The live rate, the reward breakdown and the node status come straight from your computer. Keep Ego Desktop open with this same recovery phrase, and use the same Wi-Fi or let phones reach it from the internet. What the chain has paid you is below either way.")
            .font(.footnote)
            .foregroundStyle(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var paidOnChain: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Paid to this wallet")
            if let chain {
                StatusRow(label: "All time", value: "\(Egoc.format(Double(chain.totalUegoc), digits: 4)) EGOC", color: Brand.text)
                StatusRow(label: "Last 24 hours", value: "\(Egoc.format(Double(chain.last24hUegoc), digits: 4)) EGOC", color: Brand.text)
                StatusRow(label: "Last 7 days", value: "\(Egoc.format(Double(chain.last7dUegoc), digits: 4)) EGOC", color: Brand.text)
                StatusRow(label: "Reward payments", value: "\(chain.count)", color: Brand.text)
                if let last = chain.lastAt {
                    StatusRow(label: "Last payment", value: relativeTime(last), color: Brand.muted)
                }
            } else if let chainProblem {
                Text(chainProblem).font(.footnote).foregroundStyle(Brand.danger)
            } else {
                ProgressView()
            }
            Text("Confirmed reward transactions on the chain, the same ones Ego Desktop adds up for All time.")
                .font(.caption2)
                .foregroundStyle(Brand.muted)
        }
        .card()
    }
}

private struct Counter: View {
    let label: String
    let value: String
    let caption: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.caption2.weight(.heavy)).tracking(1.5).foregroundStyle(Brand.muted)
            Text(value)
                .font(.system(size: 26, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text(caption.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.muted.opacity(0.7))
        }
    }
}

private struct Tile: View {
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(Brand.muted)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .heavy))
                .foregroundStyle(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(unit).font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.muted.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Brand.muted)
            Spacer()
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(color)
        }
    }
}

/// Formats EGOC the way Ego Desktop does: micro-units, fixed decimals, en-US grouping.
enum Egoc {
    private static func formatter(_ digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f
    }

    static func format(_ uegoc: Double, digits: Int) -> String {
        formatter(digits).string(from: NSNumber(value: uegoc / 1_000_000)) ?? "—"
    }

    static func duration(_ secs: Int64) -> String {
        if secs < 60 { return "\(secs)s" }
        if secs < 3_600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3_600)h \((secs % 3_600) / 60)m"
    }
}

/// The Earnings card on the Wallet screen.
struct EarningsCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var chain: RewardsSummary?

    var body: some View {
        NavigationLink {
            EarningsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Brand.mint.opacity(0.15))
                    .foregroundStyle(Brand.mint)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Earnings")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.text)
                    Text(chain.map { "\(Egoc.format(Double($0.totalUegoc), digits: 4)) EGOC all time · \(Egoc.format(Double($0.last24hUegoc), digits: 4)) today" }
                         ?? "Rewards from your Ego Desktop")
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Brand.muted)
            }
        }
        .buttonStyle(.plain)
        .card()
        .task { chain = try? await model.rewards() }
    }
}
