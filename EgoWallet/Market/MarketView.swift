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

    private var sideColor: Color { takerSide == .buy ? Brand.emerald : Brand.coral }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(intensity: 0.6, colors: Brand.tradeAurora)
                ScrollView {
                    VStack(spacing: 16) {
                        MarketHero(params: params, egocUsd: egocUsd).reveal(0)
                        TradeSideSwitch(side: $takerSide).reveal(0.03)
                        filters.reveal(0.06)
                        if let problem { ProblemBanner(text: problem) }
                        book
                        NoteCard(text: "The coins wait in escrow until the seller confirms the payment, and an arbiter settles disputes. To trade, open P2P Trade in Ego Desktop with the same wallet.",
                                 icon: "lock.shield.fill", tint: Brand.amber)
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await load() }
            }
            .navigationTitle("P2P Trade")
            .toolbarBackground(.hidden, for: .navigationBar)
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

    private var filters: some View {
        GlassField(label: takerSide == .buy ? "I want to buy" : "I want to sell", icon: "slider.horizontal.3") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MarketAssets.all) { a in
                        AssetChip(asset: a, on: a.id == asset, tint: sideColor) {
                            withAnimation(.spring(response: 0.3)) { asset = a.id }
                            Haptics.tap()
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    Picker(takerSide == .buy ? "Pay with" : "Get paid in", selection: $fiat) {
                        ForEach(Fiat.all) { Text("\($0.code) · \($0.name)").tag($0.code) }
                    }
                } label: {
                    MenuPill(icon: "banknote", text: fiat)
                }
                Menu {
                    Picker("Payment method", selection: $method) {
                        Text("Any method").tag("")
                        ForEach(PaymentMethods.all) { Text($0.label).tag($0.id) }
                    }
                } label: {
                    MenuPill(icon: "creditcard", text: method.isEmpty ? "Any method" : PaymentMethods.label(method))
                }
            }
            HStack(spacing: 8) {
                TextField("Any amount", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text(meta.symbol)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.muted)
            }
            .glassInput()
            if meta.group != .ego {
                Text("\(meta.symbol) trades settle on \(meta.chain): the seller locks the coins in the Ego escrow contract there, and they go to the buyer only when the seller confirms the payment or an arbiter decides.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
        }
    }

    @ViewBuilder private var book: some View {
        HStack {
            SectionLabel(text: takerSide == .buy ? "Sellers" : "Buyers")
            Spacer()
            if let offers, !offers.isEmpty {
                Text("\(offers.count)\(next != nil ? "+" : "") offer\(offers.count == 1 ? "" : "s")")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(sideColor)
            }
        }
        if let offers {
            if offers.isEmpty && problem == nil {
                VStack(spacing: 10) {
                    Image(systemName: "storefront")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [Brand.amber, Brand.coral], startPoint: .top, endPoint: .bottom))
                        .frame(width: 70, height: 70)
                        .background(Brand.amber.opacity(0.1), in: Circle())
                    Text("Nobody is \(makerSide == .sell ? "selling" : "buying") \(meta.label) for \(fiat)\(method.isEmpty ? "" : " by \(PaymentMethods.label(method))") yet.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            ForEach(Array(offers.enumerated()), id: \.element.id) { i, listing in
                NavigationLink {
                    OfferDetailView(listing: listing, egocUsd: egocUsd, mine: listing.offer.maker == app.address)
                } label: {
                    OfferRow(listing: listing, egocUsd: egocUsd, mine: listing.offer.maker == app.address)
                }
                .buttonStyle(.plain)
                .reveal(min(Double(i), 6) * 0.03)
            }
            if next != nil {
                Button(loadingMore ? "Loading…" : "Show more offers") { Task { await loadMore() } }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(loadingMore)
            }
        } else {
            ForEach(0..<3, id: \.self) { _ in OfferPlaceholder() }
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

/// The market's state at a glance: whether it's live, the EGOC price, and what's in escrow.
struct MarketHero: View {
    let params: MarketParams?
    let egocUsd: Double
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                let live = params?.active == true
                Circle()
                    .fill(live ? Brand.emerald : Brand.amber)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.4 : 1)
                    .opacity(pulse ? 0.5 : 1)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                Text(params.map { $0.active ? "Market live" : "Not live yet" } ?? "Connecting…")
                    .font(.system(.caption, design: .rounded, weight: .heavy))
                    .foregroundStyle(live ? Brand.emerald : Brand.amber)
                Spacer()
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Brand.amber)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("1 EGOC")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.muted)
                Text(egocUsd > 0 ? Fiat.formatUnitPrice(micro: UInt64((egocUsd * 1_000_000).rounded()), code: "USD") : "—")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [Brand.amber, Brand.coral], startPoint: .leading, endPoint: .trailing))
                    .contentTransition(.numericText())
            }
            HStack(spacing: 10) {
                stat("In escrow", params.map { "\(Egoc.format(Double($0.escrowHeldUegoc), digits: 2)) EGOC" } ?? "—", icon: "lock.fill")
                stat("Open trades", params.map { "\($0.activeTrades)" } ?? "—", icon: "person.2.fill")
            }
            if let params, !params.active {
                Text("The P2P market isn't switched on for this network yet. You can look around; posting offers and trading open when the network activates it.")
                    .font(.caption)
                    .foregroundStyle(Brand.amber)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(Brand.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(colors: [Brand.amber.opacity(0.6), Brand.coral.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
        )
        .shadow(color: Brand.amber.opacity(0.12), radius: 20)
    }

    private func stat(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.muted)
            Text(value)
                .font(.system(.subheadline, design: .rounded, weight: .heavy))
                .foregroundStyle(Brand.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Buy in green, sell in coral: the whole page follows the side you pick.
struct TradeSideSwitch: View {
    @Binding var side: MarketSide
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            option(.buy, "Buy", icon: "arrow.down.circle.fill", colors: [Brand.emerald, Brand.mint])
            option(.sell, "Sell", icon: "arrow.up.circle.fill", colors: [Brand.coral, Brand.amber])
        }
        .padding(4)
        .background(.ultraThinMaterial.opacity(0.55), in: Capsule())
        .background(Brand.card.opacity(0.6), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1)))
    }

    private func option(_ value: MarketSide, _ title: String, icon: String, colors: [Color]) -> some View {
        let on = side == value
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { side = value }
            Haptics.tap()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .foregroundStyle(on ? Brand.ink : Brand.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background {
                    if on {
                        Capsule()
                            .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                            .shadow(color: colors[0].opacity(0.4), radius: 10)
                            .matchedGeometryEffect(id: "side", in: pill)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct AssetChip: View {
    let asset: MarketAsset
    let on: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(asset.symbol)
                    .font(.system(.subheadline, design: .rounded, weight: .heavy))
                if asset.group != .ego {
                    Text(asset.chain)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(on ? AnyShapeStyle(tint) : AnyShapeStyle(Color.white.opacity(0.06)), in: Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : Color.white.opacity(0.12)))
            .foregroundStyle(on ? Brand.ink : Brand.text)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct MenuPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.amber)
            Text(text).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.muted)
        }
        .font(.system(.subheadline, design: .rounded, weight: .bold))
        .foregroundStyle(Brand.text)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1)))
    }
}

/// A trader's record as a ring: the share of their ratings that were good.
struct TrustRing: View {
    let profile: MakerProfile
    var size: CGFloat = 40

    private var share: Double? {
        let rated = profile.positive + profile.negative
        return rated > 0 ? Double(profile.positive) / Double(rated) : nil
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
            if let share {
                Circle()
                    .trim(from: 0, to: share)
                    .stroke(share >= 0.9 ? Brand.emerald : share >= 0.7 ? Brand.amber : Brand.coral,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(share.map { "\(Int(($0 * 100).rounded()))" } ?? "new")
                .font(.system(size: share == nil ? 9 : 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Brand.text)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(share.map { "\(Int(($0 * 100).rounded())) percent positive" } ?? "New trader")
    }
}

struct OfferRow: View {
    let listing: OfferListing
    let egocUsd: Double
    let mine: Bool

    var body: some View {
        let offer = listing.offer
        let symbol = MarketAssets.meta(offer.asset).symbol
        // A sell offer is one you buy from.
        let tint = offer.side == .sell ? Brand.emerald : Brand.coral
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4).padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unitPriceText(offer, egocUsd: egocUsd))
                            .font(.system(.title3, design: .rounded, weight: .heavy))
                            .foregroundStyle(Brand.text)
                        Text("per \(symbol) · \(offer.price.marginLabel ?? "Fixed price")")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Brand.muted)
                    }
                    Spacer()
                    if mine {
                        Text("YOU")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(Brand.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Brand.sky, in: Capsule())
                    }
                    TrustRing(profile: listing.makerProfile)
                }
                HStack(spacing: 12) {
                    Label("\(MarketAssets.number(offer.minMicro, asset: offer.asset)) – \(MarketAssets.amount(offer.maxMicro, asset: offer.asset))", systemImage: "arrow.left.and.right")
                    Label(paymentWindowLabel(seconds: offer.paymentWindowSecs), systemImage: "timer")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.text)
                Text("\(shortAddress(offer.maker)) · \(listing.makerProfile.summary)")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
                if !offer.methods.isEmpty || offer.country != nil {
                    FlowLayout(spacing: 6) {
                        ForEach(offer.methods.map(PaymentMethods.label) + [offer.country].compactMap { $0 }, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(tint.opacity(0.12), in: Capsule())
                                .foregroundStyle(tint)
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Brand.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A shimmering card while offers load.
struct OfferPlaceholder: View {
    @State private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6).frame(width: 120, height: 20)
            RoundedRectangle(cornerRadius: 5).frame(width: 200, height: 12)
            RoundedRectangle(cornerRadius: 5).frame(width: 160, height: 12)
        }
        .foregroundStyle(Color.white.opacity(on ? 0.10 : 0.04))
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
        .onAppear { on = true }
        .accessibilityHidden(true)
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
        let tint = buying ? Brand.emerald : Brand.coral
        GlassPage(aurora: Brand.tradeAurora) {
            VStack(spacing: 6) {
                Text(buying ? "Buy \(meta.symbol)" : "Sell \(meta.symbol)")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Brand.muted)
                Text(unitPriceText(offer, egocUsd: egocUsd))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [tint, Brand.amber], startPoint: .leading, endPoint: .trailing))
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
                            .background(tint.opacity(0.1), in: Capsule())
                            .overlay(Capsule().stroke(tint.opacity(0.3)))
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
                HStack(spacing: 12) {
                    TrustRing(profile: profile, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shortAddress(offer.maker)).font(.system(.callout, design: .monospaced)).foregroundStyle(Brand.text)
                        Text(profile.summary).font(.subheadline).foregroundStyle(Brand.muted)
                    }
                }
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
                     icon: "desktopcomputer", tint: Brand.amber)
        }
        .navigationTitle(buying ? "Buy \(meta.symbol)" : "Sell \(meta.symbol)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
