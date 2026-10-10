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
        NavigationStack {
            Form {
                if let made {
                    doneSections(made)
                } else {
                    priceSection
                    Section {
                        Picker("Pay with", selection: $method) {
                            ForEach(Method.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if method == .crypto { cryptoSections } else { cardSections }
                    Section {
                        SecureField("IOU password", text: $password)
                        SecureField("Confirm password", text: $password2)
                        if !password2.isEmpty && password != password2 {
                            Text("The passwords don't match.").font(.caption).foregroundStyle(Brand.danger)
                        }
                    } header: {
                        Text("IOU password")
                    } footer: {
                        Text("Encrypts your proof of purchase. Keep it: without it the IOU can't be opened.")
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                    Section {
                        if method == .crypto {
                            Button(busy ? "Making your IOU…" : "Make IOU") { makeCryptoIOU() }
                                .disabled(config == nil || egocForCrypto <= 0 || !passwordsOK || busy)
                        } else {
                            Button(busy ? "Making your IOU…" : "Make IOU") { makeCardIOU() }
                                .disabled(!cardPaid || session == nil || !passwordsOK || busy)
                        }
                    }
                }
                if !ious.isEmpty {
                    Section("Your IOUs") {
                        ForEach(ious) { iou in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(iou.egocAmount, specifier: "%.2f") EGOC").font(.subheadline.weight(.semibold))
                                    Text("\(iou.payment) · \(iou.issuedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(Brand.muted)
                                }
                                Spacer()
                                Button("Open") { opening = iou }.font(.caption.weight(.semibold))
                                ShareLink(item: iou.file) { Image(systemName: "square.and.arrow.up") }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Pre-sale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .sheet(item: $paying) { CoinSendView(asset: $0, prefilledTo: made?.depositAddress, prefilledAmount: made?.payAmount.map { String($0) }) }
            .sheet(item: $opening) { OpenIOUView(iou: $0) }
        }
    }

    private var priceSection: some View {
        Section {
            if let config {
                LabeledContent("Price", value: String(format: "$%.4f per EGOC", config.priceUsd))
                if config.launchUsd > 0 {
                    LabeledContent("Launch price", value: String(format: "$%.4f", config.launchUsd))
                }
                if !config.tierLabel.isEmpty {
                    LabeledContent("Round", value: "\(config.tierLabel) (\(config.tierIndex + 1) of \(config.tierCount))")
                }
                if config.discountPercent > 0 {
                    LabeledContent("Discount", value: "\(config.discountPercent)% off launch")
                }
            } else if let configProblem {
                Text(configProblem).foregroundStyle(Brand.danger)
            } else {
                HStack { ProgressView(); Text("Getting the price…").foregroundStyle(Brand.muted) }
            }
        } footer: {
            Text("You get an encrypted IOU file. The EGOC is credited in the Genesis Block when mainnet launches.")
        }
    }

    @ViewBuilder private var cryptoSections: some View {
        Section {
            Picker("Coin", selection: $coin) {
                ForEach(Presale.coins, id: \.self) { Text($0).tag($0) }
            }
            TextField("Amount of \(coin)", text: $payText).keyboardType(.decimalPad)
            if coinUsd > 0 && payAmount > 0 {
                LabeledContent("Worth", value: String(format: "≈ $%.2f", payAmount * coinUsd))
            }
            if let asset = payAsset, let balance = model.externalBalances[asset.id] {
                LabeledContent("You have", value: "\(balance.formatted(maxDecimals: 8)) \(coin)")
            }
        } header: {
            Text("Pay with crypto")
        }
        Section("You receive") {
            Text(egocForCrypto > 0 ? "\(egocForCrypto, specifier: "%.4f") EGOC" : "—")
                .font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Brand.mint)
        }
    }

    @ViewBuilder private var cardSections: some View {
        Section {
            TextField("Dollars (at least $10)", text: $usdText).keyboardType(.decimalPad)
            LabeledContent("You receive", value: egocForCard > 0 ? String(format: "%.2f EGOC", egocForCard) : "—")
            if session == nil {
                Button(busy ? "Opening Stripe…" : "Pay with card or Apple Pay") { startCard() }
                    .disabled(config == nil || usdAmount < Presale.minimumCardUsd || busy)
                DisclosureGroup("Already paid but lost the check?") {
                    TextField("cs_live_… session ID", text: $resumeID)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Resume") {
                        session = Presale.CardSession(sessionId: resumeID.trimmingCharacters(in: .whitespaces), checkoutURL: URL(string: Presale.service)!, egocAmount: egocForCard, usdAmount: usdAmount)
                    }
                    .disabled(resumeID.trimmingCharacters(in: .whitespaces).isEmpty || usdAmount <= 0)
                }
            } else {
                Text(cardPaid ? "Payment confirmed. Set your IOU password below." : "Finish paying in the browser, then come back and check.")
                    .font(.footnote).foregroundStyle(cardPaid ? Brand.mint : Brand.warning)
                if !cardPaid {
                    Button(busy ? "Checking…" : "Check payment") { checkCard() }.disabled(busy)
                }
            }
        } header: {
            Text("Pay by card")
        } footer: {
            Text("Checkout runs on Stripe in your browser.")
        }
    }

    @ViewBuilder private func doneSections(_ iou: PresaleIOU) -> some View {
        Section {
            Label("IOU saved", systemImage: "checkmark.seal.fill").foregroundStyle(Brand.mint)
            LabeledContent("Allocation", value: String(format: "%.4f EGOC", iou.egocAmount))
            ShareLink(item: iou.file) { Label("Save or share the IOU file", systemImage: "square.and.arrow.up") }
        } footer: {
            Text("Keep the file and its password; together they're your proof of purchase. It's also in the Files app under Ego Wallet.")
        }
        if let deposit = iou.depositAddress, let amount = iou.payAmount, let coin = iou.payCoin {
            Section {
                Text("Send \(String(amount)) \(coin) to the pre-sale treasury:").font(.footnote)
                Text(deposit).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                if let asset = model.externalAssets.first(where: { $0.asset == coin }) {
                    Button("Send now from this wallet") { paying = asset }
                }
                Button("Copy address") { UIPasteboard.general.string = deposit }
            } header: {
                Text("Pay")
            } footer: {
                Text(coin == "USDT" ? "Send USDT on Ethereum (ERC-20)." : "Send it on \(ExternalAsset.networkName(coin)).")
            }
        }
        Section { Button("Done") { dismiss() } }
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
        NavigationStack {
            Form {
                if let record {
                    Section("Allocation") {
                        ForEach(record.keys.sorted(), id: \.self) { key in
                            LabeledContent(key.replacingOccurrences(of: "_", with: " "), value: "\(record[key] ?? "")")
                                .font(.footnote)
                        }
                    }
                } else {
                    Section {
                        SecureField("IOU password", text: $password)
                        Button("Open") {
                            do {
                                record = try Presale.open(try Data(contentsOf: iou.file), password: password)
                                problem = nil
                            } catch {
                                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            }
                        }
                        .disabled(password.isEmpty)
                    }
                    if let problem { Section { Text(problem).foregroundStyle(Brand.danger) } }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("IOU")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
