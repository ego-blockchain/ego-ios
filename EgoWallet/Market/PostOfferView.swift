import EgoKit
import SwiftUI

extension AppModel {
    /// Sends a market operation (post or close an offer), signed by this wallet.
    func marketOperation<T: Encodable>(_ txType: String, _ body: T) async throws -> String {
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try MarketOps.operation(key: key, txType: txType, body: body, nonce: info.next, fee: info.feeUegoc,
                                         version: max(3, info.txVersion))
        return try await submit(tx)
    }
}

/// Ego Desktop's "Post an offer", for EGOC: the same fields and the same checks
/// the chain makes, so an offer that passes here is one the network takes.
struct PostOfferView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let egocUsd: Double

    @State var side: MarketSide
    @AppStorage("market.fiat") private var fiat = "USD"
    @State private var followMarket = false
    @State private var priceText = ""
    @State private var marginText = "0"
    @State private var minText = "10"
    @State private var maxText = "1000"
    @State private var methods: [String] = []
    @State private var windowSecs: Int64 = 3_600
    @State private var country = ""
    @State private var terms = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var postedHash: String?

    private static let windows: [Int64] = [15, 30, 60, 120, 180, 360, 720, 1_440].map { $0 * 60 }
    private var tint: Color { side == .sell ? Brand.coral : Brand.emerald }
    private var marginAllowed: Bool { fiat == "USD" }
    private var marginBps: Int? {
        Double(marginText.replacingOccurrences(of: ",", with: ".")).map { Int(($0 * 100).rounded()) }
    }

    private var priceMicro: UInt64? {
        guard let value = Double(priceText.replacingOccurrences(of: ",", with: ".")), value > 0, value.isFinite else { return nil }
        return UInt64((value * 1_000_000).rounded())
    }

    /// The price per EGOC the offer shows today.
    private var todayMicro: UInt64? {
        if followMarket && marginAllowed {
            guard let bps = marginBps, egocUsd > 0 else { return nil }
            return UInt64((egocUsd * 1_000_000 * (1 + Double(bps) / 10_000)).rounded())
        }
        return priceMicro
    }

    private var body_: MarketOps.OfferBody {
        let price: MarketOps.Price = followMarket && marginAllowed ? .marginBps(marginBps ?? 0) : .fixed(priceMicro ?? 0)
        let place = country.trimmingCharacters(in: .whitespaces).uppercased()
        return MarketOps.OfferBody(
            side: side, fiat: fiat, price: price,
            minMicro: Amount.parse(minText) ?? 0, maxMicro: Amount.parse(maxText) ?? 0,
            methods: methods, country: place.isEmpty ? nil : place,
            terms: terms.trimmingCharacters(in: .whitespacesAndNewlines), paymentWindowSecs: windowSecs
        )
    }

    private var issue: String? {
        if followMarket && marginAllowed && marginBps == nil { return "Set the margin, like 2 or -1.5." }
        return MarketOps.problem(with: body_, balance: app.spendableEGOC)
    }

    var body: some View {
        GlassPage(aurora: Brand.tradeAurora) {
            if let postedHash {
                SuccessBurst(title: "Offer posted",
                             subtitle: "It shows on P2P Trade as soon as the network confirms it, usually within seconds, and stays listed for 30 days or until you close it.")
                HashCard(hash: postedHash, explorer: EgoScan.tx(postedHash))
                Button("Done") { dismiss() }.buttonStyle(GlowButtonStyle())
            } else {
                form
            }
        }
        .navigationTitle("Post an offer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if postedHash == nil { Button("Cancel") { dismiss() }.foregroundStyle(Brand.muted) }
            }
        }
        .onAppear {
            if priceText.isEmpty, egocUsd > 0, fiat == "USD" { priceText = String(format: "%.4f", egocUsd) }
        }
    }

    @ViewBuilder private var form: some View {
        GlassSegments(selection: $side, options: [.sell, .buy]) { $0 == .sell ? "I sell EGOC" : "I buy EGOC" }
        Text(side == .sell
             ? "Buyers pay you in \(fiat), and your EGOC waits in escrow until you confirm the payment."
             : "Sellers lock their EGOC in escrow and you pay them in \(fiat); the coins come to you when they confirm.")
            .font(.caption)
            .foregroundStyle(Brand.muted)
            .frame(maxWidth: .infinity, alignment: .leading)

        GlassField(label: "Price per EGOC", icon: "tag") {
            Menu {
                Picker("Currency", selection: $fiat) {
                    ForEach(Fiat.all) { Text("\($0.code) · \($0.name)").tag($0.code) }
                }
            } label: {
                MenuPill(icon: "banknote", text: fiat)
            }
            if marginAllowed {
                GlassSegments(selection: $followMarket, options: [false, true]) { $0 ? "Follow the market" : "Fixed price" }
            }
            if followMarket && marginAllowed {
                HStack(spacing: 8) {
                    TextField("0", text: $marginText)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    Text("% over the network price").font(.subheadline).foregroundStyle(Brand.muted)
                }
                .glassInput()
            } else {
                HStack(spacing: 8) {
                    TextField("0.00", text: $priceText)
                        .keyboardType(.decimalPad)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    Text(fiat).font(.system(.subheadline, design: .rounded, weight: .bold)).foregroundStyle(Brand.muted)
                }
                .glassInput()
            }
            if egocUsd > 0 {
                Text("Network price now: \(Fiat.formatUnitPrice(micro: UInt64((egocUsd * 1_000_000).rounded()), code: "USD"))"
                     + (followMarket && marginAllowed ? " · yours today: \(todayMicro.map { Fiat.formatUnitPrice(micro: $0, code: "USD") } ?? "—")" : ""))
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
        }

        GlassField(label: "Per trade", icon: "arrow.left.and.right") {
            HStack(spacing: 10) {
                amountBox("Minimum", text: $minText)
                amountBox("Maximum", text: $maxText)
            }
            if side == .sell, let have = app.spendableEGOC {
                Text("You hold \(Amount.format(have)) EGOC. The maximum can't be more than that.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
        }

        GlassField(label: "Payment methods (\(methods.count)/\(MarketOps.maxMethods))", icon: "creditcard") {
            FlowLayout(spacing: 8) {
                ForEach(PaymentMethods.all) { m in
                    let on = methods.contains(m.id)
                    Button {
                        if on {
                            methods.removeAll { $0 == m.id }
                        } else if methods.count < MarketOps.maxMethods {
                            methods.append(m.id)
                        }
                        Haptics.tap()
                    } label: {
                        Text(m.label)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(on ? tint.opacity(0.22) : Color.white.opacity(0.05), in: Capsule())
                            .overlay(Capsule().stroke(on ? tint : Color.white.opacity(0.12)))
                            .foregroundStyle(on ? Brand.text : Brand.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        GlassField(label: "Time the buyer has to pay", icon: "timer") {
            Menu {
                Picker("Time to pay", selection: $windowSecs) {
                    ForEach(Self.windows, id: \.self) { Text(paymentWindowLabel(seconds: $0)).tag($0) }
                }
            } label: {
                MenuPill(icon: "timer", text: paymentWindowLabel(seconds: windowSecs))
            }
        }

        GlassField(label: "Country (optional)", icon: "globe") {
            TextField("e.g. DE", text: $country)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .glassInput()
        }

        GlassField(label: "Terms (optional) · \(terms.utf8.count)/\(MarketOps.maxTermsBytes)", icon: "doc.plaintext") {
            TextField("Anything the other side should know", text: $terms, axis: .vertical)
                .lineLimit(3...6)
                .glassInput()
        }

        NoteCard(text: "P2P Trade is in beta, so start with small amounts. An arbiter chosen by the DAO settles disputes. Posting costs only the network fee; trades on it are opened and run from Ego Desktop for now.",
                 icon: "lock.shield.fill", tint: Brand.amber)
        if let shown = problem ?? issue { ProblemBanner(text: shown) }
        Button {
            Task { await post() }
        } label: {
            if busy { ProgressView().tint(Brand.ink) } else { Text(side == .sell ? "Post sell offer" : "Post buy offer") }
        }
        .buttonStyle(GlowButtonStyle())
        .disabled(busy || issue != nil)
    }

    private func amountBox(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Brand.muted)
            HStack(spacing: 6) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text("EGOC").font(.system(.caption, design: .rounded, weight: .bold)).foregroundStyle(Brand.muted)
            }
            .glassInput()
        }
    }

    private func post() async {
        guard issue == nil else { return }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            let hash = try await app.marketOperation(MarketOps.postOffer, body_)
            Haptics.success()
            withAnimation(.spring(response: 0.4)) { postedHash = hash }
        } catch {
            problem = app.message(for: error)
        }
    }
}

extension MarketSide: @retroactive Identifiable {
    public var id: String { rawValue }
}
