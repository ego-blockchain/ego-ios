import EgoKit
import SwiftUI

// Every money flow in one look: details, a review card, hold to confirm, a success burst.

// MARK: - Send EGOC

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
    private var to: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var recipientOK: Bool { EgoAddress.isValid(to) }
    private var memoOK: Bool { memo.utf8.count <= Transactions.maxMemoBytes }
    private var step: Int { sentHash != nil ? 2 : reviewing ? 1 : 0 }
    private var maxSendable: UInt64? { model.balance.map { $0 > (fee ?? 0) ? $0 - (fee ?? 0) : 0 } }

    var body: some View {
        FlowSheet(icon: "arrow.up.right", title: sentHash != nil ? "On its way" : "Send EGOC",
                  subtitle: sentHash == nil ? "To any Ego address" : nil, step: step) {
            if let sentHash {
                SuccessBurst(title: "Sent", subtitle: "It shows as pending until the network confirms it, usually within seconds.")
                HashCard(hash: sentHash)
            } else if reviewing, let amount {
                SummaryCard(
                    rows: [
                        .init(label: "To", value: shortAddress(to), mono: true),
                        .init(label: "Amount", value: "\(Amount.format(amount)) EGOC"),
                        .init(label: "Network fee", value: fee.map { "\(Amount.format($0)) EGOC" } ?? "—"),
                    ] + (memo.isEmpty ? [] : [.init(label: "Memo", value: memo)]),
                    total: .init(label: "Total", value: "\(Amount.format(amount + (fee ?? 0))) EGOC")
                )
                NoteCard(text: "A payment can't be reversed once it's sent.", icon: "exclamationmark.shield.fill", tint: Brand.warning)
            } else {
                AddressInput(label: "To", placeholder: "egot1…", text: $recipient,
                             problem: recipientOK ? nil : "That isn't an Ego address.")
                AmountInput(
                    label: "Amount", unit: "EGOC", text: $amountText,
                    caption: model.balance.map { "You have \(Amount.format($0)) EGOC" },
                    problem: !amountText.isEmpty && (amount ?? 0) == 0 ? "Enter an amount with up to 6 decimals." : nil,
                    quickPicks: maxSendable.map { m in [("25%", Amount.format(m / 4)), ("50%", Amount.format(m / 2)), ("Max", Amount.format(m))] } ?? []
                )
                GlassField(label: "Memo (optional)", icon: "text.bubble") {
                    TextField("What it's for", text: $memo).foregroundStyle(Brand.text)
                    if !memoOK { Text("The memo is too long.").font(.caption).foregroundStyle(Brand.danger) }
                }
            }
            if let problem { ProblemBanner(text: problem) }
        } footer: {
            if sentHash != nil {
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            } else if reviewing, let amount {
                HoldToConfirm(title: "Hold to send \(Amount.format(amount)) EGOC", busy: busy) { Task { await send(amount) } }
                Button("Change something") { withAnimation { reviewing = false } }.buttonStyle(GhostButtonStyle()).disabled(busy)
            } else {
                Button("Review") { withAnimation(.spring) { reviewing = true } }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(!recipientOK || (amount ?? 0) == 0 || !memoOK)
            }
        }
        .task { fee = await model.networkFee() }
    }

    private func send(_ amount: UInt64) async {
        busy = true
        problem = nil
        do {
            let hash = try await model.send(to: to, amount: amount, memo: memo)
            withAnimation(.spring) { sentHash = hash }
        } catch {
            Haptics.warning()
            problem = model.message(for: error)
        }
        busy = false
    }
}

// MARK: - Receive

struct ReceiveCard: View {
    let address: String
    let unit: String
    var warning: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            if let image = QRCode.image(for: address) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 210, height: 210)
                    .padding(16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(alignment: .center) {
                        EgoMark(size: 34)
                            .padding(8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .shadow(color: Brand.lime.opacity(0.35), radius: 24)
                    .reveal(0.05)
            }
            GlassField(label: "Your \(unit) address", icon: "wallet.pass") {
                Text(address)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Brand.text)
                    .textSelection(.enabled)
            }
            .reveal(0.12)
            if let warning {
                NoteCard(text: warning, icon: "exclamationmark.triangle.fill", tint: Brand.warning).reveal(0.18)
            }
        }
    }
}

struct ReceiveView: View {
    let address: String
    @State private var copied = false

    var body: some View {
        FlowSheet(icon: "arrow.down.left", title: "Receive EGOC", subtitle: "Share this with whoever is paying you") {
            ReceiveCard(address: address, unit: "Ego")
        } footer: {
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy address") {
                    UIPasteboard.general.string = address
                    copied = true
                    Haptics.tap()
                }
                .buttonStyle(GlowButtonStyle())
                ShareLink(item: address) { Image(systemName: "square.and.arrow.up").font(.headline) }
                    .frame(width: 56, height: 56)
                    .background(Brand.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(Brand.text)
            }
        }
    }
}

// MARK: - EGUSD

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
    private var maxBurn: UInt64? { model.balance.map { $0 > (fee ?? 0) ? $0 - (fee ?? 0) : 0 } }
    private var step: Int { sentHash != nil ? 2 : reviewing ? 1 : 0 }

    var body: some View {
        FlowSheet(icon: "arrow.triangle.2.circlepath", title: sentHash != nil ? "Converted" : "Convert to EGUSD",
                  subtitle: sentHash == nil ? "Stable dollars on Ego. 1 EGUSD is always $1." : nil, step: step, tint: Brand.mint) {
            if let sentHash {
                SuccessBurst(title: "\(EGUSD.format(credits)) on the way", subtitle: "Your EGUSD shows once the network confirms it.")
                HashCard(hash: sentHash)
            } else if reviewing, let amount, let price {
                SummaryCard(rows: [
                    .init(label: "Burn", value: "\(Amount.format(amount)) EGOC"),
                    .init(label: "EGOC price", value: "$\(Amount.format(price))"),
                    .init(label: "Network fee", value: fee.map { "\(Amount.format($0)) EGOC" } ?? "—"),
                ], total: .init(label: "You get", value: EGUSD.format(credits)))
                NoteCard(text: "The EGOC is burned. EGUSD can't be turned back into EGOC.", icon: "flame.fill", tint: Brand.warning)
            } else {
                AmountInput(
                    label: "EGOC to convert", unit: "EGOC", text: $amountText,
                    caption: price.map { "At $\(Amount.format($0)) per EGOC" } ?? "Getting the EGOC price…",
                    problem: !amountText.isEmpty && (amount ?? 0) == 0 ? "Enter an amount with up to 6 decimals."
                        : !affordable ? "That's more than your balance after the network fee." : nil,
                    quickPicks: maxBurn.map { m in [("25%", Amount.format(m / 4)), ("50%", Amount.format(m / 2)), ("Max", Amount.format(m))] } ?? []
                )
                HStack {
                    Image(systemName: "arrow.down").foregroundStyle(Brand.mint)
                }
                GlassField(label: "You get", icon: "dollarsign.circle") {
                    Text(credits > 0 ? EGUSD.format(credits) : "$0.00")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(Brand.glow)
                        .frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: credits)
                }
            }
            if let problem { ProblemBanner(text: problem) }
        } footer: {
            if sentHash != nil {
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            } else if reviewing, let amount, let price {
                HoldToConfirm(title: "Hold to convert", busyTitle: "Converting…", busy: busy) { Task { await convert(amount, price: price) } }
                Button("Change something") { withAnimation { reviewing = false } }.buttonStyle(GhostButtonStyle()).disabled(busy)
            } else {
                Button("Review") { withAnimation(.spring) { reviewing = true } }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(price == nil || credits == 0 || !affordable)
            }
        }
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

    private func convert(_ amount: UInt64, price: UInt64) async {
        busy = true
        problem = nil
        do {
            let hash = try await model.convertToEGUSD(amount: amount, priceMicroUsd: price)
            withAnimation(.spring) { sentHash = hash }
        } catch {
            Haptics.warning()
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
    private var to: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var recipientOK: Bool { EgoAddress.isValid(to) && to != model.address }
    private var enough: Bool { (credits ?? 0) <= (model.credits ?? 0) }
    private var step: Int { sentHash != nil ? 2 : reviewing ? 1 : 0 }

    var body: some View {
        FlowSheet(icon: "dollarsign.circle", title: sentHash != nil ? "Paid" : "Pay EGUSD",
                  subtitle: sentHash == nil ? model.credits.map { "You have \(EGUSD.format($0))" } : nil, step: step, tint: Brand.mint) {
            if let sentHash {
                SuccessBurst(title: "Paid", subtitle: "It shows as pending until the network confirms it.")
                HashCard(hash: sentHash)
            } else if reviewing, let credits {
                SummaryCard(rows: [
                    .init(label: "To", value: shortAddress(to), mono: true),
                    .init(label: "Network fee", value: fee.map { "\(Amount.format($0)) EGOC" } ?? "—"),
                ], total: .init(label: "Amount", value: EGUSD.format(credits)))
                NoteCard(text: "A payment can't be reversed once it's sent. The network fee is paid in EGOC.", icon: "exclamationmark.shield.fill", tint: Brand.warning)
            } else {
                if model.credits == nil {
                    NoteCard(text: "No gateway reports EGUSD balances yet, so a payment can't be checked before it's sent. Try again later.", icon: "exclamationmark.triangle.fill", tint: Brand.warning)
                } else if model.credits == 0 {
                    NoteCard(text: "You don't have any EGUSD yet. Convert some EGOC first.")
                    Button("Convert EGOC") { converting = true }.buttonStyle(SecondaryButtonStyle())
                }
                AddressInput(label: "To", placeholder: "egot1…", text: $recipient,
                             problem: recipientOK ? nil : to == model.address ? "You can't pay yourself." : "That isn't an Ego address.")
                AmountInput(
                    label: "Amount", unit: "EGUSD", text: $amountText,
                    problem: !amountText.isEmpty && credits == nil ? "Enter dollars and cents, like 12.50."
                        : !enough ? "You have \(EGUSD.format(model.credits ?? 0))." : nil,
                    quickPicks: (model.credits ?? 0) > 0 ? [("All", EGUSD.format(model.credits ?? 0).replacingOccurrences(of: "$", with: ""))] : []
                )
            }
            if let problem { ProblemBanner(text: problem) }
        } footer: {
            if sentHash != nil {
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            } else if reviewing, let credits {
                HoldToConfirm(title: "Hold to pay \(EGUSD.format(credits))", busyTitle: "Paying…", busy: busy) { Task { await pay(credits) } }
                Button("Change something") { withAnimation { reviewing = false } }.buttonStyle(GhostButtonStyle()).disabled(busy)
            } else {
                Button("Review") { withAnimation(.spring) { reviewing = true } }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(!recipientOK || credits == nil || !enough || model.credits == nil)
            }
        }
        .task { fee = await model.networkFee() }
        .sheet(isPresented: $converting) { ConvertToEGUSDView() }
    }

    private func pay(_ credits: UInt64) async {
        busy = true
        problem = nil
        do {
            let hash = try await model.payEGUSD(to: to, credits: credits)
            withAnimation(.spring) { sentHash = hash }
        } catch {
            Haptics.warning()
            problem = model.message(for: error)
        }
        busy = false
    }
}

// MARK: - Other coins

struct CoinReceiveView: View {
    let asset: ExternalAsset
    @State private var copied = false

    var body: some View {
        FlowSheet(icon: "arrow.down.left", title: "Receive \(asset.asset)", subtitle: asset.networkLabel, tint: CoinStyle.color(asset.asset)) {
            ReceiveCard(address: asset.address, unit: asset.asset,
                        warning: "Only send \(asset.asset) on \(ExternalAsset.networkName(asset.chain)) to this address. Coins sent on another network can be lost.")
        } footer: {
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy address") {
                    UIPasteboard.general.string = asset.address
                    copied = true
                    Haptics.tap()
                }
                .buttonStyle(GlowButtonStyle())
                ShareLink(item: asset.address) { Image(systemName: "square.and.arrow.up").font(.headline) }
                    .frame(width: 56, height: 56)
                    .background(Brand.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(Brand.text)
            }
        }
    }
}

struct CoinSendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let asset: ExternalAsset
    @State private var recipient: String
    @State private var amount: String
    @State private var tag = ""
    @State private var prepared: PreparedTransfer?
    @State private var busy = false
    @State private var problem: String?
    @State private var sentHash: String?

    init(asset: ExternalAsset, prefilledTo: String? = nil, prefilledAmount: String? = nil) {
        self.asset = asset
        _recipient = State(initialValue: prefilledTo ?? "")
        _amount = State(initialValue: prefilledAmount ?? "")
    }

    private var to: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var recipientOK: Bool { ExternalSend.isValidAddress(to, for: asset) && to.lowercased() != asset.address.lowercased() }
    private var destinationTag: UInt32? { UInt32(tag.trimmingCharacters(in: .whitespaces)) }
    private var tagOK: Bool { tag.trimmingCharacters(in: .whitespaces).isEmpty || destinationTag != nil }
    private var amountOK: Bool {
        let t = amount.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        return !t.isEmpty && parts.count <= 2 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
            && (parts.count < 2 || parts[1].count <= asset.decimals) && t.contains(where: { $0 != "0" && $0 != "." })
    }
    private var step: Int { sentHash != nil ? 2 : prepared != nil ? 1 : 0 }
    private var tint: Color { CoinStyle.color(asset.asset) }

    var body: some View {
        FlowSheet(icon: "arrow.up.right", title: sentHash != nil ? "On its way" : "Send \(asset.asset)",
                  subtitle: sentHash == nil ? asset.networkLabel : nil, step: ExternalSend.canSend(asset) ? step : nil, tint: tint) {
            if !ExternalSend.canSend(asset) {
                NoteCard(text: "Sending \(asset.asset) from the phone is coming soon. For now, send it from Ego Desktop. You can already receive \(asset.asset) here.", icon: "clock")
            } else if let sentHash {
                SuccessBurst(title: "Sent", subtitle: "Your balance updates once the network confirms it.")
                HashCard(hash: sentHash, explorer: ExternalSend.explorerTxURL(asset, hash: sentHash))
            } else if let p = prepared {
                SummaryCard(
                    rows: [
                        .init(label: "To", value: shortAddress(p.to), mono: true),
                        .init(label: "Network", value: ExternalAsset.networkName(asset.chain)),
                        .init(label: "Network fee", value: ExternalSend.feeNote(asset) ?? "\(p.feeText) \(p.feeSymbol)"),
                    ] + (destinationTag.map { [.init(label: "Destination tag", value: "\($0)")] } ?? []),
                    total: .init(label: "Amount", value: "\(p.amountText) \(asset.asset)")
                )
                NoteCard(text: "A payment can't be reversed once it's sent. Check the address is on \(ExternalAsset.networkName(asset.chain)).", icon: "exclamationmark.shield.fill", tint: Brand.warning)
            } else {
                AddressInput(label: "To", placeholder: asset.chain == "ETH" || asset.chain == "BNB" ? "0x…" : "\(asset.asset) address", text: $recipient,
                             problem: recipientOK ? nil : to.lowercased() == asset.address.lowercased() ? "That's your own address." : "That isn't a \(ExternalAsset.networkName(asset.chain)) address.")
                if asset.chain == "XRP" {
                    GlassField(label: "Destination tag (optional)", icon: "tag") {
                        TextField("Exchanges give one with their address", text: $tag)
                            .keyboardType(.numberPad)
                            .foregroundStyle(Brand.text)
                        if !tagOK { Text("A tag is a whole number.").font(.caption).foregroundStyle(Brand.danger) }
                    }
                }
                AmountInput(
                    label: "Amount", unit: asset.asset, text: $amount,
                    caption: model.externalBalances[asset.id].map { "You have \($0.formatted(maxDecimals: 8)) \(asset.asset)" },
                    problem: !amount.isEmpty && !amountOK ? "Enter an amount with up to \(asset.decimals) decimals." : nil,
                    quickPicks: asset.contract != nil ? (model.externalBalances[asset.id].map { [("Max", $0.formatted(maxDecimals: asset.decimals))] } ?? []) : []
                )
            }
            if let problem { ProblemBanner(text: problem) }
        } footer: {
            if !ExternalSend.canSend(asset) || sentHash != nil {
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            } else if let p = prepared {
                HoldToConfirm(title: "Hold to send \(p.amountText) \(asset.asset)", busy: busy) { Task { await send(p) } }
                Button("Change something") { withAnimation { prepared = nil; problem = nil } }.buttonStyle(GhostButtonStyle()).disabled(busy)
            } else {
                Button(busy ? "Checking…" : "Review") { Task { await review() } }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(!recipientOK || !amountOK || !tagOK || busy)
            }
        }
    }

    private func review() async {
        busy = true
        problem = nil
        do {
            let p = try await model.prepareExternalSend(asset, to: to, amount: amount, destinationTag: destinationTag)
            withAnimation(.spring) { prepared = p }
        } catch {
            Haptics.warning()
            problem = model.message(for: error)
        }
        busy = false
    }

    private func send(_ p: PreparedTransfer) async {
        busy = true
        problem = nil
        do {
            let hash = try await ExternalSend.broadcast(p)
            withAnimation(.spring) { sentHash = hash }
            Task { await model.refreshExternal() }
        } catch {
            Haptics.warning()
            problem = model.message(for: error)
        }
        busy = false
    }
}

// MARK: - Shielded

struct ShieldSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var fee: UInt64?
    @State private var reviewing = false
    @State private var busy = false
    @State private var problem: String?
    @State private var hashes: [String]?

    private var amount: UInt64? { Amount.parse(amountText) }
    private var plan: (notes: [UInt64], remainder: UInt64) { Shielded.denominate(amount ?? 0) }
    private var total: UInt64 { plan.notes.reduce(0, +) }
    private var step: Int { hashes != nil ? 2 : reviewing ? 1 : 0 }

    var body: some View {
        FlowSheet(icon: "lock.shield.fill", title: hashes != nil ? "Shielding" : "Shield EGOC",
                  subtitle: hashes == nil ? "Move EGOC into the private pool" : nil, step: step) {
            if let hashes {
                SuccessBurst(title: "\(hashes.count) deposit\(hashes.count == 1 ? "" : "s") sent", subtitle: "Your notes show once the network confirms them.")
            } else if reviewing {
                SummaryCard(rows: notesRows + [
                    .init(label: "Network fees", value: fee.map { "\(Amount.format($0 * UInt64(plan.notes.count))) EGOC" } ?? "—"),
                ] + (plan.remainder > 0 ? [.init(label: "Stays unshielded", value: "\(Amount.format(plan.remainder)) EGOC")] : []),
                    total: .init(label: "Shielded", value: "\(Amount.format(total)) EGOC"))
            } else {
                AmountInput(label: "EGOC to shield", unit: "EGOC", text: $amountText,
                            caption: "Notes come in 1, 10, 100, 1,000 and 10,000 EGOC",
                            quickPicks: [("1", "1"), ("10", "10"), ("100", "100")])
                if !plan.notes.isEmpty {
                    SummaryCard(rows: notesRows)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                NoteCard(text: "Each note is its own deposit and pays the network fee.")
            }
            if let problem { ProblemBanner(text: problem) }
        } footer: {
            if hashes != nil {
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            } else if reviewing {
                HoldToConfirm(title: "Hold to shield \(Amount.format(total)) EGOC", busyTitle: "Shielding…", busy: busy) { Task { await shield() } }
                Button("Change something") { withAnimation { reviewing = false } }.buttonStyle(GhostButtonStyle()).disabled(busy)
            } else {
                Button("Review") { withAnimation(.spring) { reviewing = true } }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(plan.notes.isEmpty)
            }
        }
        .animation(.spring, value: plan.notes)
        .task { fee = await model.networkFee() }
    }

    private var notesRows: [SummaryCard.Row] {
        Dictionary(grouping: plan.notes, by: { $0 }).sorted { $0.key > $1.key }.map { value, list in
            .init(label: "\(list.count) × note", value: "\(Amount.format(value)) EGOC")
        }
    }

    private func shield() async {
        busy = true
        problem = nil
        do {
            let h = try await model.shield(amount: total)
            withAnimation(.spring) { hashes = h }
        } catch {
            Haptics.warning()
            problem = model.message(for: error)
        }
        busy = false
    }
}

struct UnshieldSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let notes: [Shielded.Note]
    @State private var chosen: Set<String> = []
    @State private var toOther = false
    @State private var recipient = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var result: (hash: String, payout: UInt64)?

    private var selected: [Shielded.Note] { notes.filter { chosen.contains($0.id) } }
    private var total: UInt64 { selected.map(\.value).reduce(0, +) }
    private var to: String { toOther ? recipient.trimmingCharacters(in: .whitespacesAndNewlines) : model.address }

    var body: some View {
        FlowSheet(icon: "lock.open.fill", title: result != nil ? "Withdrawn" : "Unshield",
                  subtitle: result == nil ? "Prove your notes privately on this iPhone" : nil, step: result != nil ? 2 : busy ? 1 : 0) {
            if let result {
                SuccessBurst(title: "\(Amount.format(result.payout)) EGOC", subtitle: "Pays out once the network confirms the proof.")
                HashCard(hash: result.hash)
            } else {
                GlassField(label: "Notes to spend", icon: "square.stack.3d.up") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        ForEach(notes) { note in
                            let on = chosen.contains(note.id)
                            Button {
                                if on { chosen.remove(note.id) } else if chosen.count < Shielded.maxSpends { chosen.insert(note.id) }
                                Haptics.tap()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: on ? "checkmark.seal.fill" : "seal")
                                        .font(.title3)
                                        .foregroundStyle(on ? Brand.lime : Brand.muted)
                                    Text("\(Amount.format(note.value))").font(.system(.headline, design: .rounded))
                                    Text("EGOC").font(.caption2).foregroundStyle(Brand.muted)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background((on ? Brand.lime.opacity(0.12) : Color.white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(on ? Brand.lime.opacity(0.6) : Color.white.opacity(0.08)))
                                .foregroundStyle(Brand.text)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                GlassField(label: "Send to", icon: "arrow.down.to.line") {
                    Toggle("Another address", isOn: $toOther.animation()).tint(Brand.lime).foregroundStyle(Brand.text)
                    if toOther {
                        TextField("egot1…", text: $recipient, axis: .vertical)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Brand.text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !recipient.isEmpty && !EgoAddress.isValid(to) {
                            Text("That isn't an Ego address.").font(.caption).foregroundStyle(Brand.danger)
                        }
                    } else {
                        Text(shortAddress(model.address)).font(.system(.footnote, design: .monospaced)).foregroundStyle(Brand.muted)
                    }
                }
                if busy {
                    NoteCard(text: "Making a zero-knowledge proof for each note. This can take a little while.", icon: "cpu", tint: Brand.lime)
                } else {
                    NoteCard(text: "Up to \(Shielded.maxSpends) notes at once. The network fee comes out of the notes.")
                }
            }
            if let problem { ProblemBanner(text: problem) }
        } footer: {
            if result != nil {
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            } else {
                HoldToConfirm(title: "Hold to unshield \(Amount.format(total)) EGOC", busyTitle: "Proving on this iPhone…", busy: busy,
                              enabled: !selected.isEmpty && EgoAddress.isValid(to)) { Task { await unshield() } }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func unshield() async {
        busy = true
        problem = nil
        do {
            let r = try await model.unshield(selected, to: to)
            withAnimation(.spring) { result = r }
            Task { await model.refreshShielded(); await model.refresh() }
        } catch {
            Haptics.warning()
            problem = model.message(for: error)
        }
        busy = false
    }
}
