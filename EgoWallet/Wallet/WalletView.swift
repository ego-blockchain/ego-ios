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
                    OtherCoinsCard()
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
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: kind.icon)
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: 52, height: 52)
                            .background((kind.incoming ? Brand.mint : Brand.lime).opacity(0.15))
                            .foregroundStyle(kind.incoming ? Brand.mint : Brand.lime)
                            .clipShape(Circle())
                        Text(kind.amount + (item.txType == "credits_pay" ? "" : " EGOC"))
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(kind.incoming ? Brand.mint : Brand.text)
                        Text(kind.title)
                            .foregroundStyle(Brand.muted)
                        if let counterparty = kind.counterparty, item.txType == "credits_mint" {
                            Text(counterparty).font(.footnote).foregroundStyle(Brand.muted)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                Section {
                    LabeledContent("Status") {
                        if let height = item.blockHeight {
                            Text("Confirmed in block \(height)").foregroundStyle(Brand.mint)
                        } else {
                            Text("Pending").foregroundStyle(Brand.warning)
                        }
                    }
                    LabeledContent("Date", value: Date(timeIntervalSince1970: TimeInterval(item.timestamp)).formatted(date: .abbreviated, time: .standard))
                    if let fee = item.feeUegoc {
                        LabeledContent("Network fee", value: "\(Amount.format(fee)) EGOC")
                    }
                    if let memo = item.memo, !memo.isEmpty, item.txType != "credits_mint", item.txType != "credits_pay" {
                        LabeledContent("Memo", value: memo)
                    }
                }
                Section {
                    copyable("From", item.from, mine: item.from == me)
                    copyable("To", item.to, mine: item.to == me)
                    copyable("Transaction", item.hash, mine: false)
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func copyable(_ label: String, _ value: String, mine: Bool) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = label
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label + (mine ? " (you)" : "")).font(.caption).foregroundStyle(Brand.muted)
                    Spacer()
                    Text(copied == label ? "Copied" : "Copy").font(.caption.weight(.semibold)).foregroundStyle(Brand.lime)
                }
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Brand.text)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}

struct SendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var amountText = ""
    @State private var memo = ""
    @State private var fee: UInt64?
    @State private var reviewing = false
    @State private var busy = false
    @State private var problem: String?
    @State private var sentHash: String?

    private var amount: UInt64? { Amount.parse(amountText) }
    private var recipientOK: Bool { EgoAddress.isValid(recipient.trimmingCharacters(in: .whitespaces)) }
    private var memoOK: Bool { memo.utf8.count <= Transactions.maxMemoBytes }

    var body: some View {
        NavigationStack {
            Form {
                if let sentHash {
                    Section {
                        Label("Sent", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.mint)
                        Text(sentHash)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } footer: {
                        Text("It shows as pending until the network confirms it, usually within a few seconds.")
                    }
                    Section { Button("Done") { dismiss() } }
                } else if reviewing, let amount {
                    Section("Check before sending") {
                        LabeledContent("To", value: shortAddress(recipient))
                        LabeledContent("Amount", value: "\(Amount.format(amount)) EGOC")
                        if let fee { LabeledContent("Network fee", value: "\(Amount.format(fee)) EGOC") }
                        if !memo.isEmpty { LabeledContent("Memo", value: memo) }
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                    Section {
                        Button(busy ? "Sending…" : "Send \(Amount.format(amount)) EGOC") { Task { await send(amount) } }
                            .disabled(busy)
                        Button("Change something") { reviewing = false }
                            .disabled(busy)
                    } footer: {
                        Text("A payment can't be reversed once it's sent.")
                    }
                } else {
                    Section("Recipient") {
                        TextField("egot1…", text: $recipient)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !recipient.isEmpty && !recipientOK {
                            Text("That isn't an Ego address.").font(.caption).foregroundStyle(Brand.danger)
                        }
                        Button("Paste") { recipient = UIPasteboard.general.string ?? recipient }
                    }
                    Section("Amount") {
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                        if !amountText.isEmpty && (amount == nil || amount == 0) {
                            Text("Enter an amount with up to 6 decimals.").font(.caption).foregroundStyle(Brand.danger)
                        }
                    }
                    Section("Memo (optional)") {
                        TextField("What it's for", text: $memo)
                        if !memoOK { Text("The memo is too long.").font(.caption).foregroundStyle(Brand.danger) }
                    }
                    Section {
                        Button("Review") { reviewing = true }
                            .disabled(!recipientOK || (amount ?? 0) == 0 || !memoOK)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Send EGOC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { fee = await model.networkFee() }
        }
    }

    private func send(_ amount: UInt64) async {
        busy = true
        problem = nil
        do {
            sentHash = try await model.send(to: recipient.trimmingCharacters(in: .whitespaces), amount: amount, memo: memo)
        } catch {
            problem = model.message(for: error)
        }
        busy = false
    }
}

struct ReceiveView: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                if let image = QRCode.image(for: address) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                Text(address)
                    .font(.system(.footnote, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                HStack(spacing: 12) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = address
                        copied = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    ShareLink(item: address) { Text("Share") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 24)
                Spacer()
            }
            .screenBackground()
            .navigationTitle("Receive EGOC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
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

struct ConvertToEGUSDView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var price: UInt64?
    @State private var fee: UInt64?
    @State private var reviewing = false
    @State private var busy = false
    @State private var problem: String?
    @State private var sentHash: String?

    private var amount: UInt64? { Amount.parse(amountText) }
    private var credits: UInt64 {
        guard let amount, let price else { return 0 }
        return EGUSD.credits(forBurning: amount, priceMicroUsd: price)
    }
    private var affordable: Bool {
        guard let amount, let balance = model.balance else { return true }
        return amount.addingReportingOverflow(fee ?? 0).partialValue <= balance
    }

    var body: some View {
        NavigationStack {
            Form {
                if let sentHash {
                    Section {
                        Label("Converted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.mint)
                        Text(sentHash)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } footer: {
                        Text("Your EGUSD shows once the network confirms it, usually within a few seconds.")
                    }
                    Section { Button("Done") { dismiss() } }
                } else if reviewing, let amount, let price {
                    Section("Check before converting") {
                        LabeledContent("Burn", value: "\(Amount.format(amount)) EGOC")
                        LabeledContent("Receive", value: EGUSD.format(credits))
                        LabeledContent("EGOC price", value: "$\(Amount.format(price))")
                        if let fee { LabeledContent("Network fee", value: "\(Amount.format(fee)) EGOC") }
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                    Section {
                        Button(busy ? "Converting…" : "Convert to \(EGUSD.format(credits))") { Task { await convert(amount, price: price) } }
                            .disabled(busy)
                        Button("Change something") { reviewing = false }
                            .disabled(busy)
                    } footer: {
                        Text("The EGOC is burned. EGUSD can't be turned back into EGOC.")
                    }
                } else {
                    Section {
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                        if let balance = model.balance {
                            Button("Use all (\(Amount.format(balance.saturatingSub(fee ?? 0))) EGOC)") {
                                amountText = Amount.format(balance.saturatingSub(fee ?? 0))
                            }
                        }
                        if !amountText.isEmpty && (amount == nil || amount == 0) {
                            Text("Enter an amount with up to 6 decimals.").font(.caption).foregroundStyle(Brand.danger)
                        } else if !affordable {
                            Text("That's more than your balance after the network fee.").font(.caption).foregroundStyle(Brand.danger)
                        }
                    } header: {
                        Text("EGOC to convert")
                    } footer: {
                        if let price {
                            Text("At $\(Amount.format(price)) per EGOC you get \(EGUSD.format(credits)).")
                        } else {
                            Text("Getting the EGOC price…")
                        }
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                    Section {
                        Button("Review") { reviewing = true }
                            .disabled(price == nil || credits == 0 || !affordable)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Convert to EGUSD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                fee = await model.networkFee()
                do {
                    let p = try await model.egocPriceMicroUsd()
                    if p > 0 { price = p } else { problem = "There's no EGOC price right now, so EGUSD can't be minted." }
                } catch {
                    problem = model.message(for: error)
                }
            }
        }
    }

    private func convert(_ amount: UInt64, price: UInt64) async {
        busy = true
        problem = nil
        do {
            sentHash = try await model.convertToEGUSD(amount: amount, priceMicroUsd: price)
        } catch {
            problem = model.message(for: error)
        }
        busy = false
    }
}

struct PayEGUSDView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var amountText = ""
    @State private var fee: UInt64?
    @State private var reviewing = false
    @State private var busy = false
    @State private var problem: String?
    @State private var sentHash: String?
    @State private var converting = false

    private var credits: UInt64? { EGUSD.parse(amountText) }
    private var to: String { recipient.trimmingCharacters(in: .whitespaces) }
    private var recipientOK: Bool { EgoAddress.isValid(to) && to != model.address }
    private var enough: Bool { (credits ?? 0) <= (model.credits ?? 0) }

    var body: some View {
        NavigationStack {
            Form {
                if let sentHash {
                    Section {
                        Label("Sent", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.mint)
                        Text(sentHash)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } footer: {
                        Text("It shows as pending until the network confirms it, usually within a few seconds.")
                    }
                    Section { Button("Done") { dismiss() } }
                } else if reviewing, let credits {
                    Section("Check before paying") {
                        LabeledContent("To", value: shortAddress(to))
                        LabeledContent("Amount", value: EGUSD.format(credits))
                        if let fee { LabeledContent("Network fee", value: "\(Amount.format(fee)) EGOC") }
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                    Section {
                        Button(busy ? "Paying…" : "Pay \(EGUSD.format(credits))") { Task { await pay(credits) } }
                            .disabled(busy)
                        Button("Change something") { reviewing = false }
                            .disabled(busy)
                    } footer: {
                        Text("A payment can't be reversed once it's sent. The network fee is paid in EGOC.")
                    }
                } else {
                    if model.credits == nil {
                        Section {
                            Label("The gateway you're connected to doesn't report EGUSD balances yet, so a payment can't be checked before it's sent. Try again later.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Brand.warning)
                        }
                    } else if model.credits == 0 {
                        Section {
                            Label("You don't have any EGUSD yet. Convert some EGOC first.", systemImage: "info.circle")
                                .foregroundStyle(Brand.muted)
                            Button("Convert EGOC") { converting = true }
                        }
                    } else if let credits = model.credits {
                        Section { LabeledContent("You have", value: EGUSD.format(credits)) }
                    }
                    Section("Recipient") {
                        TextField("egot1…", text: $recipient)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !recipient.isEmpty && !recipientOK {
                            Text(to == model.address ? "You can't pay yourself." : "That isn't an Ego address.")
                                .font(.caption).foregroundStyle(Brand.danger)
                        }
                        Button("Paste") { recipient = UIPasteboard.general.string ?? recipient }
                    }
                    Section {
                        TextField("$0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                        if !amountText.isEmpty && credits == nil {
                            Text("Enter dollars and cents, like 12.50.").font(.caption).foregroundStyle(Brand.danger)
                        } else if !enough {
                            Text("You have \(EGUSD.format(model.credits ?? 0)).").font(.caption).foregroundStyle(Brand.danger)
                        }
                    } header: {
                        Text("Amount in EGUSD")
                    }
                    Section {
                        Button("Review") { reviewing = true }
                            .disabled(!recipientOK || credits == nil || !enough || model.credits == nil)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Pay EGUSD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { fee = await model.networkFee() }
            .sheet(isPresented: $converting) { ConvertToEGUSDView() }
        }
    }

    private func pay(_ credits: UInt64) async {
        busy = true
        problem = nil
        do {
            sentHash = try await model.payEGUSD(to: to, credits: credits)
        } catch {
            problem = model.message(for: error)
        }
        busy = false
    }
}

private extension UInt64 {
    func saturatingSub(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
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

struct CoinReceiveView: View {
    let asset: ExternalAsset
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let image = QRCode.image(for: asset.address) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    Text(asset.address)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Brand.text)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Label("Only send \(asset.asset) on \(ExternalAsset.networkName(asset.chain)) to this address. Coins sent on another network can be lost.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Brand.warning)
                    Button(copied ? "Copied" : "Copy address") {
                        UIPasteboard.general.string = asset.address
                        copied = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    ShareLink(item: asset.address) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(24)
            }
            .screenBackground()
            .navigationTitle("Receive \(asset.asset)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct CoinSendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let asset: ExternalAsset
    @State private var recipient = ""
    @State private var amount = ""
    @State private var prepared: PreparedTransfer?
    @State private var busy = false
    @State private var problem: String?
    @State private var sentHash: String?

    private var to: String { recipient.trimmingCharacters(in: .whitespaces) }
    private var recipientOK: Bool { ExternalSend.isValidAddress(to, for: asset) && to.lowercased() != asset.address.lowercased() }
    private var amountOK: Bool {
        let t = amount.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        return !t.isEmpty && parts.count <= 2 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
            && (parts.count < 2 || parts[1].count <= asset.decimals) && t.contains(where: { $0 != "0" && $0 != "." })
    }

    var body: some View {
        NavigationStack {
            Form {
                if !ExternalSend.canSend(asset) {
                    Section {
                        Label("Sending \(asset.asset) from the phone is coming soon. For now, send it from Ego Desktop. You can already receive \(asset.asset) here.", systemImage: "clock")
                            .foregroundStyle(Brand.muted)
                    }
                } else if let sentHash {
                    Section {
                        Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.mint)
                        Text(sentHash).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if let url = ExternalSend.explorerTxURL(asset, hash: sentHash) {
                            Link("View on explorer", destination: url)
                        }
                    } footer: {
                        Text("Your balance updates once the network confirms it.")
                    }
                    Section { Button("Done") { dismiss() } }
                } else if let p = prepared {
                    Section("Check before sending") {
                        LabeledContent("To", value: shortAddress(p.to))
                        LabeledContent("Amount", value: "\(p.amountText) \(asset.asset)")
                        LabeledContent("Network fee", value: "\(p.feeText) \(p.feeSymbol)")
                        LabeledContent("Network", value: ExternalAsset.networkName(asset.chain))
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                    Section {
                        Button(busy ? "Sending…" : "Send \(asset.asset)") { Task { await send(p) } }
                            .disabled(busy)
                        Button("Change something") { prepared = nil; problem = nil }
                            .disabled(busy)
                    } footer: {
                        Text("A payment can't be reversed once it's sent. Check the address is on \(ExternalAsset.networkName(asset.chain)).")
                    }
                } else {
                    Section("Recipient") {
                        TextField(asset.chain == "ETH" || asset.chain == "BNB" ? "0x…" : "Address", text: $recipient)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !recipient.isEmpty && !recipientOK {
                            Text(to.lowercased() == asset.address.lowercased() ? "That's your own address." : "That isn't a \(ExternalAsset.networkName(asset.chain)) address.")
                                .font(.caption).foregroundStyle(Brand.danger)
                        }
                        Button("Paste") { recipient = UIPasteboard.general.string ?? recipient }
                    }
                    Section {
                        TextField("0.00", text: $amount).keyboardType(.decimalPad)
                        if let balance = model.externalBalances[asset.id] {
                            if asset.contract != nil {
                                Button("Use all (\(balance.formatted(maxDecimals: asset.decimals)) \(asset.asset))") {
                                    amount = balance.formatted(maxDecimals: asset.decimals)
                                }
                            } else {
                                Text("You have \(balance.formatted(maxDecimals: 8)) \(asset.asset)").font(.caption).foregroundStyle(Brand.muted)
                            }
                        }
                    } header: {
                        Text("Amount in \(asset.asset)")
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                    Section {
                        Button(busy ? "Checking…" : "Review") { Task { await review() } }
                            .disabled(!recipientOK || !amountOK || busy)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Send \(asset.asset)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func review() async {
        busy = true
        problem = nil
        do {
            prepared = try await model.prepareExternalSend(asset, to: to, amount: amount)
        } catch {
            problem = model.message(for: error)
        }
        busy = false
    }

    private func send(_ p: PreparedTransfer) async {
        busy = true
        problem = nil
        do {
            sentHash = try await ExternalSend.broadcast(p)
            Task { await model.refreshExternal() }
        } catch {
            problem = model.message(for: error)
        }
        busy = false
    }
}
