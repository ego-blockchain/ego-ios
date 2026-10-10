import EgoKit
import SwiftUI

/// The EGOC pre-sale on the Wallet screen, as in Ego Desktop.
struct PresaleCard: View {
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Brand.lime.opacity(0.15))
                    .foregroundStyle(Brand.lime)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("EGOC pre-sale").font(.headline).foregroundStyle(Brand.text)
                    Text("Buy at the pre-sale price, credited at the Genesis Block").font(.footnote).foregroundStyle(Brand.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.muted.opacity(0.6))
            }
            .card()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) { PresaleView() }
    }
}

struct PresaleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Method: String, CaseIterable { case crypto = "Crypto", card = "Card" }

    @State private var config: Presale.Config?
    @State private var configProblem: String?
    @State private var prices: [String: Double] = [:]
    @State private var method = Method.crypto
    @State private var coin = "ETH"
    @State private var payText = ""
    @State private var usdText = ""
    @State private var password = ""
    @State private var password2 = ""
    @State private var session: Presale.CardSession?
    @State private var cardPaid = false
    @State private var resumeID = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var made: PresaleIOU?
    @State private var paying: ExternalAsset?
    @State private var ious: [PresaleIOU] = PresaleIOU.all()
    @State private var opening: PresaleIOU?

    private var payAmount: Double { Double(payText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var usdAmount: Double { Double(usdText.replacingOccurrences(of: ",", with: ".")) ?? 0 }
    private var coinUsd: Double { prices[coin] ?? 0 }
    private var egocForCrypto: Double {
        guard let price = config?.priceUsd, price > 0, coinUsd > 0 else { return 0 }
        return payAmount * coinUsd / price
    }
    private var egocForCard: Double {
        guard let price = config?.priceUsd, price > 0 else { return 0 }
        return (usdAmount / price * 100).rounded(.down) / 100
    }
    private var passwordsOK: Bool { !password.trimmingCharacters(in: .whitespaces).isEmpty && password == password2 }

    var body: some View {
        FlowSheet(icon: made == nil ? "sparkles" : "checkmark.seal.fill",
                  title: made == nil ? "EGOC pre-sale" : "IOU saved",
                  subtitle: made == nil ? "Credited in the Genesis Block when mainnet launches" : nil) {
            if let made {
                doneContent(made)
            } else {
                priceCard.reveal(0.02)
                GlassSegments(selection: $method, options: Method.allCases) { $0.rawValue }.reveal(0.06)
                Group {
                    if method == .crypto { cryptoContent } else { cardContent }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                passwordCard
            }
            if let problem { ProblemBanner(text: problem) }
            if !ious.isEmpty { iouList }
        } footer: {
            if made != nil {
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            } else if method == .crypto {
                Button(busy ? "Making your IOU…" : "Make IOU") { makeCryptoIOU() }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(config == nil || egocForCrypto <= 0 || !passwordsOK || busy)
            } else {
                Button(busy ? "Making your IOU…" : "Make IOU") { makeCardIOU() }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(!cardPaid || session == nil || !passwordsOK || busy)
            }
        }
        .task { await load() }
        .sheet(item: $paying) { CoinSendView(asset: $0, prefilledTo: made?.depositAddress, prefilledAmount: made?.payAmount.map { String($0) }) }
        .sheet(item: $opening) { OpenIOUView(iou: $0) }
    }

    @ViewBuilder private var priceCard: some View {
        if let config {
            SummaryCard(
                rows: (config.launchUsd > 0 ? [.init(label: "Launch price", value: String(format: "$%.4f", config.launchUsd))] : [])
                    + (config.tierLabel.isEmpty ? [] : [.init(label: "Round", value: "\(config.tierLabel) (\(config.tierIndex + 1) of \(config.tierCount))")])
                    + (config.discountPercent > 0 ? [.init(label: "Discount", value: "\(config.discountPercent)% off launch")] : []),
                total: .init(label: "Pre-sale price", value: String(format: "$%.4f", config.priceUsd))
            )
        } else if let configProblem {
            ProblemBanner(text: configProblem)
        } else {
            GlassField(label: "Price", icon: "dollarsign.circle") {
                HStack(spacing: 10) {
                    ProgressView().tint(Brand.lime)
                    Text("Getting the price…").foregroundStyle(Brand.muted)
                }
            }
        }
    }

    private func receiveField(_ egoc: Double, decimals: Int) -> some View {
        GlassField(label: "You receive", icon: "sparkles") {
            Text(egoc > 0 ? String(format: "%.\(decimals)f EGOC", egoc) : "—")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Brand.glow)
                .contentTransition(.numericText())
                .animation(.snappy, value: egoc)
        }
    }

    @ViewBuilder private var cryptoContent: some View {
        GlassField(label: "Pay with", icon: "bitcoinsign.circle") {
            ChipPicker(selection: $coin, options: Presale.coins)
        }
        AmountInput(
            label: "Amount", unit: coin, text: $payText,
            caption: [
                coinUsd > 0 && payAmount > 0 ? String(format: "≈ $%.2f", payAmount * coinUsd) : nil,
                payAsset.flatMap { model.externalBalances[$0.id] }.map { "You have \($0.formatted(maxDecimals: 8)) \(coin)" },
            ].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        )
        receiveField(egocForCrypto, decimals: 4)
    }

    @ViewBuilder private var cardContent: some View {
        AmountInput(
            label: "Dollars", unit: "USD", text: $usdText,
            caption: String(format: "At least $%.0f", Presale.minimumCardUsd),
            quickPicks: [("$50", "50"), ("$100", "100"), ("$500", "500")]
        )
        receiveField(egocForCard, decimals: 2)
        if session == nil {
            Button {
                startCard()
            } label: {
                Label(busy ? "Opening Stripe…" : "Pay with card or Apple Pay", systemImage: "creditcard.fill")
            }
            .buttonStyle(OutlineButtonStyle())
            .disabled(config == nil || usdAmount < Presale.minimumCardUsd || busy)
            NoteCard(text: "Checkout runs on Stripe in your browser.", icon: "lock.fill")
            GlassField(label: "Already paid?", icon: "arrow.uturn.backward") {
                DisclosureGroup("Resume with the checkout session ID") {
                    VStack(spacing: 10) {
                        TextField("cs_live_…", text: $resumeID)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .glassInput()
                        Button("Resume") {
                            session = Presale.CardSession(sessionId: resumeID.trimmingCharacters(in: .whitespaces), checkoutURL: URL(string: Presale.service)!, egocAmount: egocForCard, usdAmount: usdAmount)
                        }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(resumeID.trimmingCharacters(in: .whitespaces).isEmpty || usdAmount <= 0)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                .foregroundStyle(Brand.text)
                .tint(Brand.lime)
            }
        } else {
            NoteCard(text: cardPaid ? "Payment confirmed. Set your IOU password below." : "Finish paying in the browser, then come back and check.",
                     icon: cardPaid ? "checkmark.circle.fill" : "clock.fill",
                     tint: cardPaid ? Brand.mint : Brand.warning)
            if !cardPaid {
                Button {
                    checkCard()
                } label: {
                    Label(busy ? "Checking…" : "Check payment", systemImage: "arrow.clockwise")
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(busy)
            }
        }
    }

    private var passwordCard: some View {
        GlassField(label: "IOU password", icon: "key.fill") {
            SecureField("Password", text: $password).glassInput()
            SecureField("Confirm password", text: $password2).glassInput()
            if !password2.isEmpty && password != password2 {
                Label("The passwords don't match.", systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(Brand.danger)
            }
            Text("Encrypts your proof of purchase. Keep it: without it the IOU can't be opened.")
                .font(.footnote).foregroundStyle(Brand.muted)
        }
    }

    @ViewBuilder private func doneContent(_ iou: PresaleIOU) -> some View {
        SuccessBurst(title: String(format: "%.4f EGOC", iou.egocAmount),
                     subtitle: "Keep the file and its password; together they're your proof of purchase. It's also in the Files app under Ego Wallet.")
        ShareLink(item: iou.file) { Label("Save or share the IOU file", systemImage: "square.and.arrow.up") }
            .buttonStyle(OutlineButtonStyle())
        if let deposit = iou.depositAddress, let amount = iou.payAmount, let coin = iou.payCoin {
            GlassField(label: "Now pay \(String(amount)) \(coin)", icon: "arrow.up.right") {
                Text("Send it to the pre-sale treasury:").font(.footnote).foregroundStyle(Brand.muted)
                Text(deposit)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Brand.text)
                    .textSelection(.enabled)
                Text(coin == "USDT" ? "Send USDT on Ethereum (ERC-20)." : "Send it on \(ExternalAsset.networkName(coin)).")
                    .font(.caption).foregroundStyle(Brand.warning)
                HStack(spacing: 10) {
                    if let asset = model.externalAssets.first(where: { $0.asset == coin }) {
                        Button("Send now") { paying = asset }.buttonStyle(OutlineButtonStyle())
                    }
                    Button("Copy address") {
                        UIPasteboard.general.string = deposit
                        Haptics.tap()
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }

    private var iouList: some View {
        GlassField(label: "Your IOUs", icon: "doc.text.fill") {
            ForEach(ious) { iou in
                HStack(spacing: 12) {
                    Image(systemName: "seal.fill")
                        .foregroundStyle(Brand.lime)
                        .frame(width: 34, height: 34)
                        .background(Brand.lime.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(iou.egocAmount, specifier: "%.2f") EGOC").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.text)
                        Text("\(iou.payment) · \(iou.issuedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(Brand.muted)
                    }
                    Spacer()
                    Button("Open") { opening = iou }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.lime)
                    ShareLink(item: iou.file) { Image(systemName: "square.and.arrow.up") }
                        .foregroundStyle(Brand.lime)
                }
            }
        }
    }

    private var payAsset: ExternalAsset? { model.externalAssets.first { $0.asset == coin } }

    private func load() async {
        do { config = try await Presale.config() } catch { configProblem = model.message(for: error) }
        prices = (try? await Presale.coinPrices()) ?? [:]
        if model.externalAssets.isEmpty { await model.refreshExternal() }
    }

    private func makeCryptoIOU() {
        guard let config else { return }
        busy = true
        problem = nil
        do {
            let data = try Presale.cryptoIOU(mainnet: model.mainnetAddress, testnet: model.address, coin: coin, amount: payAmount, coinUsd: coinUsd, priceUsd: config.priceUsd, password: password)
            made = try PresaleIOU.save(data)
            ious = PresaleIOU.all()
        } catch {
            problem = model.message(for: error)
        }
        busy = false
    }

    private func startCard() {
        busy = true
        problem = nil
        Task {
            do {
                let s = try await Presale.startCardCheckout(usd: usdAmount)
                session = s
                openURL(s.checkoutURL)
            } catch {
                problem = model.message(for: error)
            }
            busy = false
        }
    }

    private func checkCard() {
        guard let session else { return }
        busy = true
        problem = nil
        Task {
            do {
                let status = try await Presale.checkCard(sessionId: session.sessionId)
                cardPaid = status.paid
                if !status.paid { problem = "Payment not confirmed yet (\(status.status)). Try again in a moment." }
            } catch {
                problem = model.message(for: error)
            }
            busy = false
        }
    }

    private func makeCardIOU() {
        guard let session else { return }
        busy = true
        problem = nil
        do {
            let egoc = session.egocAmount > 0 ? session.egocAmount : egocForCard
            let usd = session.usdAmount > 0 ? session.usdAmount : usdAmount
            let data = try Presale.cardIOU(mainnet: model.mainnetAddress, testnet: model.address, session: session.sessionId, egocAmount: egoc, usdAmount: usd, password: password)
            made = try PresaleIOU.save(data)
            ious = PresaleIOU.all()
        } catch {
            problem = model.message(for: error)
        }
        busy = false
    }
}

/// Opens an IOU with its password to show the private allocation record.
struct OpenIOUView: View {
    let iou: PresaleIOU
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var record: [String: Any]?
    @State private var problem: String?

    var body: some View {
        FlowSheet(icon: record == nil ? "lock.doc.fill" : "doc.text.magnifyingglass",
                  title: record == nil ? "Open IOU" : "Allocation",
                  subtitle: String(format: "%.2f EGOC · ", iou.egocAmount) + iou.payment) {
            if let record {
                SummaryCard(rows: record.keys.sorted().map {
                    .init(label: $0.replacingOccurrences(of: "_", with: " ").capitalized, value: "\(record[$0] ?? "")")
                })
            } else {
                GlassField(label: "IOU password", icon: "key.fill") {
                    SecureField("Password", text: $password).glassInput().onSubmit(open)
                }
                if let problem { ProblemBanner(text: problem) }
            }
        } footer: {
            if record != nil {
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            } else {
                Button("Open", action: open).buttonStyle(GlowButtonStyle()).disabled(password.isEmpty)
            }
        }
    }

    private func open() {
        guard !password.isEmpty else { return }
        do {
            let opened = try Presale.open(try Data(contentsOf: iou.file), password: password)
            withAnimation(.spring) { record = opened }
            problem = nil
            Haptics.success()
        } catch {
            Haptics.warning()
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
