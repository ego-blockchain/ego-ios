import EgoKit
import SwiftUI

/// Ego Desktop's P2P Trade page: the same assets, filters, prices and limits.
/// Trading itself still happens in Ego Desktop.
struct MarketView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage("market.fiat") private var fiat = "USD"
    @AppStorage("market.asset") private var asset = "EGOC"
    @State private var takerSide: MarketSide = .buy
    @State private var method = ""
    @State private var amountText = ""
    @State private var offers: [OfferListing]?
    @State private var next: String?
    @State private var egocUsd: Double = 0
    @State private var params: MarketParams?
    @State private var problem: String?
    @State private var loadingMore = false

    /// Taking a sell offer is buying, so the book shows the other side.
    private var makerSide: MarketSide { takerSide == .buy ? .sell : .buy }
    private var meta: MarketAsset { MarketAssets.meta(asset) }
    private var amountMicro: UInt64? { Amount.parse(amountText).flatMap { $0 > 0 ? $0 : nil } }
    private var reloadKey: String { "\(takerSide.rawValue)-\(asset)-\(fiat)-\(method)-\(amountMicro ?? 0)" }

    var body: some View {
        NavigationStack {
            List {
                Section { header }
                Section {
                    Picker("Side", selection: $takerSide) {
                        Text("Buy").tag(MarketSide.buy)
                        Text("Sell").tag(MarketSide.sell)
                    }
                    .pickerStyle(.segmented)
                    Picker(takerSide == .buy ? "Buy" : "Sell", selection: $asset) {
                        ForEach(MarketAsset.Group.allCases, id: \.self) { group in
                            Section(group.rawValue) {
                                ForEach(MarketAssets.all.filter { $0.group == group }) { a in
                                    Text(a.group == .ego ? a.symbol : "\(a.symbol) · \(a.chain)").tag(a.id)
                                }
                            }
                        }
                    }
                    Picker(takerSide == .buy ? "Pay with" : "Get paid in", selection: $fiat) {
                        ForEach(Fiat.all) { Text("\($0.code) · \($0.name)").tag($0.code) }
                    }
                    Picker("Payment method", selection: $method) {
                        Text("Any method").tag("")
                        ForEach(PaymentMethods.all) { Text($0.label).tag($0.id) }
                    }
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("Any", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                        Text(meta.symbol).foregroundStyle(Brand.muted)
                    }
                } footer: {
                    if meta.group != .ego {
                        Text("\(meta.symbol) trades settle on \(meta.chain): the seller locks the coins in the Ego escrow contract there, and they go to the buyer only when the seller confirms the payment or an arbiter decides.")
                    }
                }
                if let problem {
                    Section { ProblemBanner(text: problem) }
                }
                Section {
                    if let offers {
                        if offers.isEmpty && problem == nil {
                            Text("Nobody is \(makerSide == .sell ? "selling" : "buying") \(meta.label) for \(fiat)\(method.isEmpty ? "" : " by \(PaymentMethods.label(method))") yet.")
                                .foregroundStyle(Brand.muted)
                        }
                        ForEach(offers) { listing in
                            NavigationLink {
                                OfferDetailView(listing: listing, egocUsd: egocUsd, mine: listing.offer.maker == app.address)
                            } label: {
                                OfferRow(listing: listing, egocUsd: egocUsd, mine: listing.offer.maker == app.address)
                            }
                        }
                        if next != nil {
                            Button(loadingMore ? "Loading…" : "Show more offers") { Task { await loadMore() } }
                                .disabled(loadingMore)
                        }
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                } header: {
                    Text(takerSide == .buy ? "Sellers" : "Buyers")
                } footer: {
                    Text("The coins wait in escrow until the seller confirms the payment, and an arbiter settles disputes. To trade, open P2P Trade in Ego Desktop with the same wallet.")
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("P2P Trade")
            .refreshable { await load() }
            .task(id: reloadKey) {
                offers = nil
                next = nil
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await load()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    if Task.isCancelled { break }
                    await load()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(params.map { $0.active ? "LIVE" : "NOT LIVE YET" } ?? "…")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((params?.active == true ? Brand.mint : Brand.warning).opacity(0.15))
                    .foregroundStyle(params?.active == true ? Brand.mint : Brand.warning)
                    .clipShape(Capsule())
                Spacer()
                if egocUsd > 0 {
                    Text("1 EGOC ≈ \(Fiat.formatUnitPrice(micro: UInt64((egocUsd * 1_000_000).rounded()), code: "USD"))")
                        .font(.caption.monospaced())
                        .foregroundStyle(Brand.muted)
                }
            }
            if let params {
                LabeledContent("EGOC in escrow now") {
                    Text("\(Egoc.format(Double(params.escrowHeldUegoc), digits: 2)) EGOC · \(params.activeTrades) trades")
                        .font(.footnote.monospaced())
                }
                .font(.footnote)
                if !params.active {
                    Text("The P2P market isn't switched on for this network yet. You can look around; posting offers and trading open when the network activates it.")
                        .font(.caption)
                        .foregroundStyle(Brand.warning)
                }
            }
        }
    }

    private func load() async {
        let (side, asset, fiat, method, amount) = (makerSide, asset, fiat, method, amountMicro)
        let key = reloadKey
        do {
            async let price = try? app.perform { try await $0.egocPriceUsd() }
            async let market = try? app.perform { try await $0.marketParams() }
            let page = try await app.perform {
                try await $0.marketOffers(asset: asset, fiat: fiat, side: side, method: method.isEmpty ? nil : method, amountMicro: amount)
            }
            let (p, m) = await (price, market)
            guard !Task.isCancelled, key == reloadKey else { return }
            if let p { egocUsd = p }
            if let m { params = m }
            offers = page.offers.filter(\.open)
            next = page.next
            problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            if offers == nil { offers = [] }
            problem = app.message(for: error)
        }
    }

    private func loadMore() async {
        guard let cursor = next else { return }
        let (side, asset, fiat, method, amount) = (makerSide, asset, fiat, method, amountMicro)
        let key = reloadKey
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await app.perform {
                try await $0.marketOffers(asset: asset, fiat: fiat, side: side, method: method.isEmpty ? nil : method, amountMicro: amount, cursor: cursor)
            }
            guard key == reloadKey else { return }
            let seen = Set((offers ?? []).map(\.id))
            offers = (offers ?? []) + page.offers.filter { $0.open && !seen.contains($0.id) }
            next = page.next
            problem = nil
        } catch {
            problem = app.message(for: error)
        }
    }
}

private func unitPriceText(_ offer: MarketOffer, egocUsd: Double) -> String {
    offer.unitPriceMicro(egocUsd: egocUsd).map { Fiat.formatUnitPrice(micro: $0, code: offer.fiat) } ?? "—"
}

struct OfferRow: View {
    let listing: OfferListing
    let egocUsd: Double
    let mine: Bool

    var body: some View {
        let offer = listing.offer
        let symbol = MarketAssets.meta(offer.asset).symbol
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(unitPriceText(offer, egocUsd: egocUsd))
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(Brand.text)
                Text("\(offer.price.marginLabel ?? "Fixed price") · per \(symbol)")
                    .font(.caption2)
                    .foregroundStyle(Brand.muted)
                Spacer()
                if mine {
                    Text("YOU")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.blue)
                }
            }
            Text("\(MarketAssets.number(offer.minMicro, asset: offer.asset)) – \(MarketAssets.amount(offer.maxMicro, asset: offer.asset)) · pay within \(paymentWindowLabel(seconds: offer.paymentWindowSecs))")
                .font(.caption)
                .foregroundStyle(Brand.text)
            Text("\(shortAddress(offer.maker)) · \(listing.makerProfile.summary)")
                .font(.caption)
                .foregroundStyle(Brand.muted)
            if !offer.methods.isEmpty || offer.country != nil {
                Text((offer.methods.map(PaymentMethods.label) + [offer.country].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.lime)
            }
        }
        .padding(.vertical, 4)
    }
}

struct OfferDetailView: View {
    let listing: OfferListing
    let egocUsd: Double
    let mine: Bool

    var body: some View {
        let offer = listing.offer
        let profile = listing.makerProfile
        let meta = MarketAssets.meta(offer.asset)
        let buying = offer.side == .sell
        GlassPage {
            VStack(spacing: 6) {
                Text(buying ? "Buy \(meta.symbol)" : "Sell \(meta.symbol)")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.muted)
                Text(unitPriceText(offer, egocUsd: egocUsd))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(Brand.glow)
                    .multilineTextAlignment(.center)
                Text("per \(meta.symbol) · \(offer.price.marginLabel ?? "Fixed price")")
                    .font(.footnote)
                    .foregroundStyle(Brand.muted)
            }
            .padding(.vertical, 8)
            .reveal(0.02)
            SummaryCard(rows: [
                .init(label: "Limits", value: "\(MarketAssets.number(offer.minMicro, asset: offer.asset)) – \(MarketAssets.amount(offer.maxMicro, asset: offer.asset))"),
                .init(label: "Pay within", value: paymentWindowLabel(seconds: offer.paymentWindowSecs)),
            ] + (meta.group != .ego ? [.init(label: "Escrow on", value: meta.chain)] : [])
              + ((offer.country ?? "").isEmpty ? [] : [.init(label: "Country", value: offer.country ?? "")]))
            .reveal(0.06)
            GlassField(label: "Payment methods", icon: "creditcard") {
                FlowLayout(spacing: 8) {
                    ForEach(offer.methods, id: \.self) { method in
                        Text(PaymentMethods.label(method))
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Brand.lime.opacity(0.1), in: Capsule())
                            .overlay(Capsule().stroke(Brand.lime.opacity(0.3)))
                            .foregroundStyle(Brand.text)
                    }
                }
            }
            .reveal(0.1)
            if !offer.terms.isEmpty {
                GlassField(label: buying ? "Seller's terms" : "Buyer's terms", icon: "doc.plaintext") {
                    Text(offer.terms)
                        .font(.subheadline)
                        .foregroundStyle(Brand.text)
                        .textSelection(.enabled)
                }
                .reveal(0.13)
            }
            GlassField(label: buying ? "Seller" : "Buyer", icon: "person.crop.circle.badge.checkmark") {
                Text(shortAddress(offer.maker)).font(.system(.callout, design: .monospaced)).foregroundStyle(Brand.text)
                Text(profile.summary).font(.subheadline).foregroundStyle(Brand.muted)
                HStack(spacing: 14) {
                    Label("\(profile.positive)", systemImage: "hand.thumbsup.fill").foregroundStyle(Brand.mint)
                    Label("\(profile.neutral)", systemImage: "minus.circle.fill").foregroundStyle(Brand.muted)
                    Label("\(profile.negative)", systemImage: "hand.thumbsdown.fill").foregroundStyle(Brand.danger)
                }
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(profile.positive) good, \(profile.neutral) neutral, \(profile.negative) bad")
            }
            .reveal(0.16)
            if profile.disputesLost > 0 {
                NoteCard(text: "Lost \(profile.disputesLost) dispute\(profile.disputesLost == 1 ? "" : "s").", icon: "exclamationmark.triangle.fill", tint: Brand.danger)
            }
            NoteCard(text: mine
                     ? "This is your offer. Manage it in Ego Desktop."
                     : "To \(buying ? "buy from" : "sell to") this trader, open P2P Trade in Ego Desktop with the same wallet.",
                     icon: "desktopcomputer")
        }
        .navigationTitle(buying ? "Buy \(meta.symbol)" : "Sell \(meta.symbol)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
