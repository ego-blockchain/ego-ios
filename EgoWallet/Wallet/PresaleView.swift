import EgoKit
import SwiftUI

/// The EGOC pre-sale on the Wallet screen, as in Ego Desktop.
struct PresaleCard: View {
    @State private var open = false
    @State private var config: Presale.Config?
    @State private var glow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            Haptics.tap()
            open = true
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Label(config.map { "\($0.tierLabel) round open" } ?? "Pre-sale open", systemImage: "sparkles")
                        .font(.system(.caption, design: .rounded, weight: .heavy))
                        .foregroundStyle(Brand.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Brand.glow, in: Capsule())
                    if let config, config.discountPercent > 0 {
                        Text("\(config.discountPercent)% below launch price")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(Brand.lime)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Get EGOC before the Genesis Block")
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(Brand.text)
                    if let config {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "$%.3f", config.priceUsd))
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .foregroundStyle(Brand.glow)
                            Text("per EGOC")
                                .font(.subheadline)
                                .foregroundStyle(Brand.muted)
                            if config.launchUsd > config.priceUsd {
                                Text(String(format: "$%.3f", config.launchUsd))
                                    .font(.subheadline)
                                    .strikethrough()
                                    .foregroundStyle(Brand.muted.opacity(0.7))
                            }
                        }
                    } else {
                        Text("Quantum-safe from block one. Credited at mainnet launch.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.muted)
                    }
                }
                HStack {
                    Text("Pay with card, Apple Pay or crypto")
                        .font(.footnote)
                        .foregroundStyle(Brand.muted)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Buy EGOC")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                    .foregroundStyle(Brand.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Brand.glow, in: Capsule())
                    .shadow(color: Brand.lime.opacity(0.4), radius: 10, y: 3)
                }
            }
            .padding(18)
            .background {
                ZStack {
                    Brand.card
                    Circle()
                        .fill(Brand.lime.opacity(0.22))
                        .frame(width: 220, height: 220)
                        .blur(radius: 60)
                        .offset(x: glow ? 120 : 60, y: -70)
                    Circle()
                        .fill(Brand.violet.opacity(0.2))
                        .frame(width: 200, height: 200)
                        .blur(radius: 60)
                        .offset(x: glow ? -140 : -90, y: 80)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AngularGradient(colors: [Brand.lime, Brand.mint, Brand.violet, Brand.lime], center: .center), lineWidth: 1.2)
                    .opacity(0.7)
            )
            // The glow reaches past the card; clipping hides it but doesn't stop it catching
            // taps meant for the Earnings card above.
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .task {
            if config == nil { config = try? await Presale.config() }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) { glow = true }
        }
        .sheet(isPresented: $open) { PresaleView() }
    }
}

/// Seed → Private → Launch, with the open round lit up.
struct PriceLadder: View {
    let config: Presale.Config
    @State private var pulse = false

    private struct Step: Identifiable {
        let label: String
        let price: Double
        let detail: String
        let state: Int // -1 done, 0 now, 1 later
        var id: String { label }
    }

    private var steps: [Step] {
        var steps = config.tiers.enumerated().map { i, t in
            Step(label: t.label, price: t.priceUsd,
                 detail: t.cap > 0 ? "\(Int(t.cap / 1_000_000))M EGOC" : "",
                 state: i < config.tierIndex ? -1 : i == config.tierIndex ? 0 : 1)
        }
        if steps.isEmpty {
            steps = [Step(label: config.tierLabel.isEmpty ? "Now" : config.tierLabel, price: config.priceUsd, detail: "", state: 0)]
        }
        if config.launchUsd > 0 {
            steps.append(Step(label: "Launch", price: config.launchUsd, detail: "Planned", state: 1))
        }
        return steps
    }

    var body: some View {
        GlassField(label: "Price by round", icon: "chart.bar.fill") {
            HStack(alignment: .bottom, spacing: 10) {
                let top = steps.map(\.price).max() ?? 1
                ForEach(steps) { step in
                    VStack(spacing: 6) {
                        if step.state == 0 {
                            Text("NOW")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(Brand.ink)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Brand.glow, in: Capsule())
                                .scaleEffect(pulse ? 1.08 : 1)
                        }
                        Text(String(format: "$%.3f", step.price))
                            .font(.system(.subheadline, design: .rounded, weight: .heavy))
                            .foregroundStyle(step.state == 0 ? Brand.lime : Brand.text)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(step.state == 0 ? AnyShapeStyle(Brand.glow) : AnyShapeStyle(Color.white.opacity(step.state < 0 ? 0.06 : 0.12)))
                            .frame(height: max(18, 90 * step.price / top))
                            .shadow(color: step.state == 0 ? Brand.lime.opacity(0.45) : .clear, radius: 10)
                        Text(step.label)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(step.state == 0 ? Brand.text : Brand.muted)
                        if !step.detail.isEmpty {
                            Text(step.detail).font(.caption2).foregroundStyle(Brand.muted)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
            Text("Each round has a fixed price, set by the pre-sale. The next round starts when this one's allocation is gone.")
                .font(.caption)
                .foregroundStyle(Brand.muted)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// What makes Ego different, in three tiles.
struct WhyEgo: View {
    private let points: [(String, String, String)] = [
        ("lock.shield.fill", "Quantum-safe from block one", "Dilithium and Kyber keys alongside Ed25519, at genesis, not a migration later."),
        ("square.stack.3d.up.fill", "Three resources, one chain", "Storage, wireless coverage and compute, proven and settled natively."),
        ("chevron.left.forwardslash.chevron.right", "Built in the open", "Written in Rust, with the full source history on GitHub."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHY EGO")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(Brand.muted)
            ForEach(Array(points.enumerated()), id: \.offset) { i, point in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: point.0)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Brand.lime)
                        .frame(width: 38, height: 38)
                        .background(Brand.lime.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.1).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Brand.text)
                        Text(point.2).font(.footnote).foregroundStyle(Brand.muted)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08)))
                .reveal(0.08 + Double(i) * 0.06)
            }
        }
    }
}

/// Pay → IOU → Genesis.
struct PresaleSteps: View {
    var body: some View {
        GlassField(label: "How it works", icon: "list.number") {
            ForEach(Array([
                ("creditcard.fill", "Pay", "With a card, Apple Pay, or BTC, ETH, BNB, SOL, ADA, TRX and USDT."),
                ("doc.badge.lock", "Keep your IOU", "An encrypted proof of purchase, saved on this iPhone and in Files."),
                ("cube.transparent.fill", "Receive at genesis", "Your EGOC is credited in the Genesis Block when mainnet launches."),
            ].enumerated()), id: \.offset) { i, step in
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Brand.glow).frame(width: 30, height: 30)
                        Text("\(i + 1)").font(.system(.subheadline, design: .rounded, weight: .heavy)).foregroundStyle(Brand.ink)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Label(step.1, systemImage: step.0)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(Brand.text)
                        Text(step.2).font(.footnote).foregroundStyle(Brand.muted)
                    }
                }
            }
        }
    }
}

struct PresaleView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Method: String, CaseIterable { case card = "Card", crypto = "Crypto" }

    @State private var config: Presale.Config?
    @State private var configProblem: String?
    @State private var prices: [String: Double] = [:]
    @State private var method = Method.card
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
                WhyEgo()
                GlassSegments(selection: $method, options: Method.allCases) { $0.rawValue }.reveal(0.06)
                Group {
                    if method == .crypto { cryptoContent } else { cardContent }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                // A card payer needs the password only once the payment has gone through.
                if method == .crypto || cardPaid { passwordCard }
                PresaleSteps()
                NoteCard(text: "Ego is on public testnet. Mainnet has no launch date yet and the security audit is still planned. EGOC has no market price, so only spend what you can afford to lose.",
                         icon: "exclamationmark.shield.fill", tint: Brand.warning)
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
                cardFooter
            }
        }
        .task { await load() }
        .sheet(item: $paying) { CoinSendView(asset: $0, prefilledTo: made?.depositAddress, prefilledAmount: made?.payAmount.map { String($0) }) }
        .sheet(item: $opening) { OpenIOUView(iou: $0) }
    }

    @ViewBuilder private var priceCard: some View {
        if let config {
            PriceLadder(config: config)
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
        }
    }

    /// The bottom button in Card mode follows the payment: pay, then check it, then make the IOU.
    @ViewBuilder private var cardFooter: some View {
        if session == nil {
            Button {
                startCard()
            } label: {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "creditcard.fill")
                        Image(systemName: "apple.logo")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(busy ? "Opening Stripe…" : "Card or Apple Pay")
                            .font(.system(.headline, design: .rounded, weight: .heavy))
                        Text("Visa · Mastercard · Amex")
                            .font(.caption2.weight(.medium))
                            .opacity(0.6)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .heavy))
                }
            }
            .buttonStyle(CardPayButtonStyle())
            .disabled(config == nil || usdAmount < Presale.minimumCardUsd || busy)
        } else if !cardPaid {
            Button {
                checkCard()
            } label: {
                Label(busy ? "Checking…" : "Check payment", systemImage: "arrow.clockwise")
            }
            .buttonStyle(GlowButtonStyle())
            .disabled(busy)
        } else {
            Button(busy ? "Making your IOU…" : "Make IOU") { makeCardIOU() }
                .buttonStyle(GlowButtonStyle())
                .disabled(!passwordsOK || busy)
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

/// The card checkout button: large and white, set apart from the lime buttons elsewhere.
struct CardPayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .white.opacity(isEnabled ? 0.18 : 0), radius: 16, y: 6)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
