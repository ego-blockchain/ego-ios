import CoreImage.CIFilterBuiltins
import EgoKit
import SwiftUI

struct WalletView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sending = false
    @State private var receiving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    balanceCard
                    EGUSDCard()
                    ShieldedCard()
                    OtherCoinsCard()
                    PresaleCard()
                    EarningsCard()
                    if let problem = model.problem {
                        ProblemBanner(text: problem)
                    }
                    ActivitySection()
                }
                .padding(16)
            }
            .refreshable {
                async let ego: Void = model.refresh()
                async let others: Void = model.refreshExternal()
                _ = await (ego, others)
            }
            .screenBackground()
            .navigationTitle("Wallet")
            .sheet(isPresented: $sending) { SendView() }
            .sheet(isPresented: $receiving) { ReceiveView(address: model.address) }
            .task { await model.refresh() }
        }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Balance")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.balance.map { Amount.format($0, maxDecimals: 2) } ?? "…")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(Brand.text)
                    .contentTransition(.numericText())
                Text("EGOC")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Brand.lime)
            }
            Text(shortAddress(model.address))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Brand.muted)
            HStack(spacing: 12) {
                Button {
                    sending = true
                } label: {
                    Label("Send", systemImage: "arrow.up.right")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button {
                    receiving = true
                } label: {
                    Label("Receive", systemImage: "arrow.down.left")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .card()
    }
}

/// The wallet's transactions a page at a time, 5, 10 or 50 to a page.
struct ActivitySection: View {
    static let pageSizes = [5, 10, 50]

    @EnvironmentObject private var model: AppModel
    @AppStorage("ego.activity.pageSize") private var pageSize = 10
    @State private var page = 0
    @State private var loadingOlder = false
    @State private var selected: HistoryItem?

    private var size: Int { ActivitySection.pageSizes.contains(pageSize) ? pageSize : 10 }
    private var pageCount: Int { max(1, (model.history.count + size - 1) / size) }
    private var shown: ArraySlice<HistoryItem> {
        let start = min(page * size, model.history.count)
        return model.history[start..<min(start + size, model.history.count)]
    }
    private var hasOlder: Bool { page + 1 < pageCount || model.mayHaveOlderHistory }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Activity")
                Spacer()
                Picker("Per page", selection: $pageSize) {
                    ForEach(ActivitySection.pageSizes, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            if model.history.isEmpty {
                Text(model.refreshing ? "Loading…" : "No transactions yet.")
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { item in
                        Button { selected = item } label: {
                            ActivityRow(item: item, me: model.address)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if item.id != shown.last?.id {
                            Divider().overlay(Brand.line)
                        }
                    }
                }
                .card()
                if page > 0 || hasOlder {
                    pager
                }
            }
        }
        .sheet(item: $selected) { TransactionDetailView(item: $0, me: model.address) }
        .onChange(of: pageSize) { _, _ in page = 0 }
        .onChange(of: model.history.count) { _, _ in page = min(page, pageCount - 1) }
    }

    private var pager: some View {
        HStack {
            Button {
                page -= 1
            } label: {
                Label("Newer", systemImage: "chevron.left")
            }
            .disabled(page == 0)
            Spacer()
            Text("\(page * size + 1)–\(page * size + shown.count) of \(model.history.count)\(model.mayHaveOlderHistory ? "+" : "")")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Brand.muted)
                .monospacedDigit()
            Spacer()
            Button {
                Task { await older() }
            } label: {
                if loadingOlder {
                    ProgressView()
                } else {
                    Label("Older", systemImage: "chevron.right").labelStyle(TrailingIconLabelStyle())
                }
            }
            .disabled(!hasOlder || loadingOlder)
        }
        .font(.system(.subheadline, design: .rounded, weight: .semibold))
        .padding(.horizontal, 4)
    }

    private func older() async {
        if page + 1 < pageCount {
            page += 1
            return
        }
        loadingOlder = true
        let before = model.history.count
        await model.loadOlderHistory()
        loadingOlder = false
        if model.history.count > before {
            page += 1
        }
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

/// How a transaction reads from this wallet's side.
struct ActivityKind {
    let title: String
    let counterparty: String?
    let amount: String
    let incoming: Bool
    let icon: String

    init(_ item: HistoryItem, me: String) {
        let incoming = item.to == me && item.from != me
        switch item.txType {
        case "credits_mint":
            let credits = EGUSD.credits(forBurning: item.amount, priceMicroUsd: Self.memoNumber(item.memo, "credits_mint:") ?? 0)
            title = "Converted to EGUSD"
            counterparty = credits > 0 ? "Got \(EGUSD.format(credits))" : nil
            amount = "−\(Amount.format(item.amount, maxDecimals: 4))"
            self.incoming = false
            icon = "arrow.triangle.2.circlepath"
        case "credits_pay":
            let credits = Self.memoNumber(item.memo, "credits_pay:") ?? 0
            title = incoming ? "Received EGUSD" : "Paid EGUSD"
            counterparty = incoming ? "From \(shortAddress(item.from))" : "To \(shortAddress(item.to))"
            amount = "\(incoming ? "+" : "−")\(EGUSD.format(credits))"
            self.incoming = incoming
            icon = "dollarsign.circle"
        default:
            title = incoming ? "Received" : "Sent"
            counterparty = incoming ? "From \(shortAddress(item.from))" : "To \(shortAddress(item.to))"
            amount = "\(incoming ? "+" : "−")\(Amount.format(item.amount, maxDecimals: 4))"
            self.incoming = incoming
            icon = incoming ? "arrow.down.left" : "arrow.up.right"
        }
    }

    static func memoNumber(_ memo: String?, _ prefix: String) -> UInt64? {
        guard let memo, memo.hasPrefix(prefix) else { return nil }
        return memo.dropFirst(prefix.count).split(separator: ":").first.flatMap { UInt64($0) }
    }
}

struct ActivityRow: View {
    let item: HistoryItem
    let me: String

    var body: some View {
        let kind = ActivityKind(item, me: me)
        HStack(spacing: 12) {
            Image(systemName: kind.icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .background((kind.incoming ? Brand.mint : Brand.lime).opacity(0.15))
                .foregroundStyle(kind.incoming ? Brand.mint : Brand.lime)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.text)
                if let counterparty = kind.counterparty {
                    Text(counterparty)
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(kind.amount)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(kind.incoming ? Brand.mint : Brand.text)
                Text(item.blockHeight == nil ? "Pending" : relativeTime(item.timestamp))
                    .font(.caption)
                    .foregroundStyle(item.blockHeight == nil ? Brand.warning : Brand.muted)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.muted.opacity(0.6))
        }
        .padding(.vertical, 10)
    }
}

/// Everything about one transaction, opened from Activity.
struct TransactionDetailView: View {
    let item: HistoryItem
    let me: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        let kind = ActivityKind(item, me: me)
        let tint = kind.incoming ? Brand.mint : Brand.lime
        FlowSheet(icon: kind.icon, title: kind.amount + (item.txType == "credits_pay" ? "" : " EGOC"), subtitle: kind.title, tint: tint) {
            if let counterparty = kind.counterparty, item.txType == "credits_mint" {
                Text(counterparty).font(.footnote).foregroundStyle(Brand.muted)
            }
            HStack(spacing: 8) {
                Circle().fill(item.blockHeight == nil ? Brand.warning : Brand.mint).frame(width: 8, height: 8)
                Text(item.blockHeight.map { "Confirmed in block \($0)" } ?? "Pending")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(item.blockHeight == nil ? Brand.warning : Brand.mint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background((item.blockHeight == nil ? Brand.warning : Brand.mint).opacity(0.12), in: Capsule())
            .reveal(0.02)
            SummaryCard(rows: [
                .init(label: "Date", value: Date(timeIntervalSince1970: TimeInterval(item.timestamp)).formatted(date: .abbreviated, time: .standard)),
            ] + (item.feeUegoc.map { [.init(label: "Network fee", value: "\(Amount.format($0)) EGOC")] } ?? [])
              + ((item.memo.map { !$0.isEmpty } ?? false) && item.txType != "credits_mint" && item.txType != "credits_pay"
                 ? [.init(label: "Memo", value: item.memo ?? "")] : []))
            .reveal(0.06)
            copyable("From", item.from, mine: item.from == me).reveal(0.1)
            copyable("To", item.to, mine: item.to == me).reveal(0.13)
            copyable("Transaction", item.hash, mine: false).reveal(0.16)
        } footer: {
            Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
        }
    }

    private func copyable(_ label: String, _ value: String, mine: Bool) -> some View {
        GlassField(label: label + (mine ? " (you)" : ""), icon: label == "Transaction" ? "number.square" : "person.crop.circle", trailing: AnyView(
            Button(copied == label ? "Copied" : "Copy") {
                UIPasteboard.general.string = value
                copied = label
                Haptics.tap()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Brand.lime)
        )) {
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Brand.text)
                .textSelection(.enabled)
        }
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// EGUSD on the Wallet screen, with Convert and Pay as in Ego Desktop.
struct EGUSDCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var converting = false
    @State private var paying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "EGUSD")
                Spacer()
                Text(model.credits.map(EGUSD.format) ?? "—")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.text)
                    .monospacedDigit()
            }
            Text(model.credits == nil
                 ? "The gateway you're connected to doesn't report EGUSD yet."
                 : "Stable dollars on Ego. 1 EGUSD is always $1.")
                .font(.footnote)
                .foregroundStyle(Brand.muted)
            HStack(spacing: 12) {
                Button {
                    converting = true
                } label: {
                    Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    paying = true
                } label: {
                    Label("Pay", systemImage: "dollarsign.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .card()
        .sheet(isPresented: $converting) { ConvertToEGUSDView() }
        .sheet(isPresented: $paying) { PayEGUSDView() }
    }
}


/// Coins on other chains, held at the addresses Ego Desktop derives from
/// the same seed.
struct OtherCoinsCard: View {
    static let collapsedCount = 3

    @EnvironmentObject private var model: AppModel
    @State private var selected: ExternalAsset?
    @AppStorage("ego.otherCoins.expanded") private var expanded = false

    /// Coins holding something first, then Ego Desktop's order.
    private var ordered: [ExternalAsset] {
        let held = model.externalAssets.filter { model.externalBalances[$0.id].map { !$0.isZero } ?? false }
        return held + model.externalAssets.filter { a in !held.contains(a) }
    }
    private var shown: [ExternalAsset] {
        expanded ? ordered : Array(ordered.prefix(OtherCoinsCard.collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Other coins")
                .padding(.bottom, 6)
            if let problem = model.externalProblems["*"] {
                Text(problem).font(.footnote).foregroundStyle(Brand.danger)
            } else if model.externalAssets.isEmpty {
                Text("Loading…").font(.footnote).foregroundStyle(Brand.muted)
            }
            ForEach(shown) { asset in
                Button { selected = asset } label: { CoinRow(asset: asset) }
                    .buttonStyle(.plain)
                if asset.id != shown.last?.id {
                    Divider().overlay(Brand.line)
                }
            }
            if model.externalAssets.count > OtherCoinsCard.collapsedCount {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Show less" : "Show all \(model.externalAssets.count)")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Brand.lime)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .card()
        .task { await model.refreshExternal() }
        .sheet(item: $selected) { CoinDetailView(asset: $0) }
    }
}

enum CoinStyle {
    static func color(_ asset: String) -> Color {
        let hex: [String: UInt32] = [
            "BTC": 0xF7931A, "ETH": 0x627EEA, "BNB": 0xF3BA2F, "SOL": 0x9945FF, "ADA": 0x3CC8C8,
            "XRP": 0x00AAE4, "TRX": 0xEF0027, "LTC": 0xA5A5A5, "DOGE": 0xC2A633, "USDT": 0x26A17B, "USDC": 0x2775CA,
        ]
        let v = hex[asset] ?? 0x888888
        return Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func glyph(_ asset: String) -> String {
        ["BTC": "₿", "ETH": "Ξ", "BNB": "◆", "SOL": "◎", "ADA": "₳", "XRP": "✕", "TRX": "T", "LTC": "Ł", "DOGE": "Ð", "USDT": "$", "USDC": "$"][asset] ?? "•"
    }
}

struct CoinBadge: View {
    let asset: String
    var size: CGFloat = 34

    var body: some View {
        Text(CoinStyle.glyph(asset))
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .frame(width: size, height: size)
            .background(CoinStyle.color(asset).opacity(0.18))
            .foregroundStyle(CoinStyle.color(asset))
            .clipShape(Circle())
    }
}

struct CoinRow: View {
    @EnvironmentObject private var model: AppModel
    let asset: ExternalAsset

    var body: some View {
        HStack(spacing: 12) {
            CoinBadge(asset: asset.asset)
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.asset)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.text)
                Text(asset.networkLabel)
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
            Spacer()
            Group {
                if let balance = model.externalBalances[asset.id] {
                    Text(balance.formatted())
                        .foregroundStyle(balance.isZero ? Brand.muted : Brand.text)
                } else if model.externalProblems[asset.id] != nil {
                    Text("—").foregroundStyle(Brand.muted)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.muted.opacity(0.6))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// One coin: its balance, with Send and Receive.
struct CoinDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let asset: ExternalAsset
    @State private var sending = false
    @State private var receiving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    CoinBadge(asset: asset.asset, size: 56)
                    VStack(spacing: 4) {
                        Text(model.externalBalances[asset.id].map { "\($0.formatted(maxDecimals: 8)) \(asset.asset)" } ?? "…")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(Brand.text)
                            .monospacedDigit()
                        Text(asset.networkLabel).foregroundStyle(Brand.muted)
                        if let problem = model.externalProblems[asset.id] {
                            Text(problem).font(.caption).foregroundStyle(Brand.danger).multilineTextAlignment(.center)
                        }
                    }
                    HStack(spacing: 12) {
                        Button { sending = true } label: { Label("Send", systemImage: "arrow.up.right") }
                            .buttonStyle(PrimaryButtonStyle())
                        Button { receiving = true } label: { Label("Receive", systemImage: "arrow.down.left") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Your \(asset.asset) address")
                        Text(asset.address)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Brand.text)
                            .textSelection(.enabled)
                        if let url = asset.explorerURL {
                            Link("View on explorer", destination: url)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Brand.lime)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle(asset.asset)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $receiving) { CoinReceiveView(asset: asset) }
            .sheet(isPresented: $sending) { CoinSendView(asset: asset) }
        }
    }
}

