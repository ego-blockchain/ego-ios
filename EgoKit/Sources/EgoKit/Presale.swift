import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(EgoWalletCore)
import EgoWalletCore
#endif

/// The EGOC pre-sale, as in Ego Desktop's wallet: the live price from the
/// payments service, an encrypted IOU file as proof of purchase, and payment
/// in crypto to the treasury or by card through Stripe.
public enum Presale {
    public static let service = "https://pay.egoblockchain.com"
    /// Coins Ego Desktop accepts, in its order.
    public static let coins = ["BTC", "ETH", "BNB", "SOL", "ADA", "TRX", "USDT"]
    public static let minimumCardUsd = 10.0

    public struct Config: Equatable, Sendable {
        public let priceUsd: Double
        public let launchUsd: Double
        public let discountPercent: Int
        public let tierLabel: String
        public let tierIndex: Int
        public let tierCount: Int
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case service(String)
        case noPrice
        case library(String)

        public var errorDescription: String? {
            switch self {
            case .service(let why): return why
            case .noPrice: return "The pre-sale price isn't available right now, so buying is paused. Try again shortly."
            case .library(let why): return why
            }
        }
    }

    /// No fallback price: an IOU written at a guessed price is a debt to the buyer.
    public static func config() async throws -> Config {
        let json = try await ExternalBalances.getJSON("\(service)/presale/config")
        if let error = json["error"] as? String { throw Failure.service(error) }
        let price = (json["price_usd"] as? NSNumber)?.doubleValue ?? 0
        guard price.isFinite, price > 0 else { throw Failure.noPrice }
        return Config(
            priceUsd: price,
            launchUsd: (json["launch_usd"] as? NSNumber)?.doubleValue ?? 0,
            discountPercent: (json["discount_pct"] as? NSNumber)?.intValue ?? 0,
            tierLabel: json["tier_label"] as? String ?? "",
            tierIndex: (json["tier_index"] as? NSNumber)?.intValue ?? 0,
            tierCount: (json["tier_count"] as? NSNumber)?.intValue ?? 1
        )
    }

    /// Dollar prices for the pre-sale coins: Binance first, then CoinGecko, as Ego Desktop does.
    public static func coinPrices() async throws -> [String: Double] {
        var prices: [String: Double] = ["USDT": 1, "USDC": 1]
        let pairs = ["BTC", "ETH", "BNB", "SOL", "ADA", "TRX"]
        let symbols = pairs.map { "\"\($0)USDT\"" }.joined(separator: ",")
        if let url = URL(string: "https://api.binance.com/api/v3/ticker/price?symbols=[\(symbols)]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
           let data = try? await ExternalBalances.fetch(URLRequest(url: url)),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in list {
                if let sym = item["symbol"] as? String, let p = Double(item["price"] as? String ?? "") {
                    prices[String(sym.dropLast(4))] = p
                }
            }
        }
        if prices.count < pairs.count + 2 {
            let ids = ["BTC": "bitcoin", "ETH": "ethereum", "BNB": "binancecoin", "SOL": "solana", "ADA": "cardano", "TRX": "tron"]
            let json = try await ExternalBalances.getJSON("https://api.coingecko.com/api/v3/simple/price?ids=\(ids.values.joined(separator: ","))&vs_currencies=usd")
            for (sym, id) in ids where prices[sym] == nil {
                if let p = ((json[id] as? [String: Any])?["usd"] as? NSNumber)?.doubleValue { prices[sym] = p }
            }
        }
        return prices
    }

    public struct CardSession: Equatable, Sendable {
        public let sessionId: String
        public let checkoutURL: URL
        public let egocAmount: Double
        public let usdAmount: Double

        public init(sessionId: String, checkoutURL: URL, egocAmount: Double, usdAmount: Double) {
            self.sessionId = sessionId
            self.checkoutURL = checkoutURL
            self.egocAmount = egocAmount
            self.usdAmount = usdAmount
        }
    }

    /// Starts a Stripe checkout. The service prices the order from the dollars alone.
    public static func startCardCheckout(usd: Double) async throws -> CardSession {
        let json = try await ExternalBalances.postJSON("\(service)/presale/checkout", ["usd_amount": usd])
        if let error = json["error"] as? String { throw Failure.service(error) }
        guard let id = json["session_id"] as? String, !id.isEmpty,
              let url = (json["checkout_url"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.service("No checkout link came back.")
        }
        return CardSession(
            sessionId: id, checkoutURL: url,
            egocAmount: (json["egoc_amount"] as? NSNumber)?.doubleValue ?? 0,
            usdAmount: (json["usd_amount"] as? NSNumber)?.doubleValue ?? usd
        )
    }

    public struct CardStatus: Equatable, Sendable {
        public let paid: Bool
        public let status: String
        public let amountCents: Int
    }

    public static func checkCard(sessionId: String) async throws -> CardStatus {
        let escaped = sessionId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? sessionId
        let json = try await ExternalBalances.getJSON("\(service)/presale/verify/\(escaped)")
        if let error = json["error"] as? String { throw Failure.service(error) }
        return CardStatus(
            paid: json["paid"] as? Bool ?? false,
            status: json["status"] as? String ?? "",
            amountCents: (json["amount_total"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// An IOU file's JSON, written as Ego Desktop writes it.
    public static func makeIOU(_ request: [String: Any]) throws -> Data {
        #if canImport(EgoWalletCore)
        let body = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let json: String = body.withCString { c in
            guard let raw = ego_wallet_presale_iou(c) else { return "" }
            defer { ego_wallet_string_free(raw) }
            return String(cString: raw)
        }
        return try checked(json)
        #else
        throw ExternalWalletError.unavailable
        #endif
    }

    public static func cryptoIOU(mainnet: String, testnet: String, coin: String, amount: Double, coinUsd: Double, priceUsd: Double, password: String) throws -> Data {
        try makeIOU([
            "kind": "crypto", "mainnet_address": mainnet, "testnet_address": testnet, "password": password,
            "now": Int(Date().timeIntervalSince1970), "pay_symbol": coin, "pay_amount": amount,
            "pay_usd_price": coinUsd, "presale_price": priceUsd,
        ])
    }

    public static func cardIOU(mainnet: String, testnet: String, session: String, egocAmount: Double, usdAmount: Double, password: String) throws -> Data {
        try makeIOU([
            "kind": "stripe", "mainnet_address": mainnet, "testnet_address": testnet, "password": password,
            "now": Int(Date().timeIntervalSince1970), "session_id": session, "egoc_amount": egocAmount, "usd_amount": usdAmount,
        ])
    }

    /// The private allocation record inside an IOU file.
    public static func open(_ iou: Data, password: String) throws -> [String: Any] {
        #if canImport(EgoWalletCore)
        let text = String(decoding: iou, as: UTF8.self)
        let json: String = text.withCString { i in
            password.withCString { p in
                guard let raw = ego_wallet_presale_open(i, p) else { return "" }
                defer { ego_wallet_string_free(raw) }
                return String(cString: raw)
            }
        }
        return try JSONSerialization.jsonObject(with: try checked(json)) as? [String: Any] ?? [:]
        #else
        throw ExternalWalletError.unavailable
        #endif
    }

    static func checked(_ json: String) throws -> Data {
        let data = Data(json.utf8)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? String, object.count == 1 {
            throw Failure.library(error)
        }
        guard !json.isEmpty else { throw Failure.library("No answer from the library.") }
        return data
    }
}

/// An IOU file kept on this iPhone, with its public parts.
public struct PresaleIOU: Identifiable, Equatable, Sendable {
    public let id: String
    public let file: URL
    public let issuedAt: Date
    public let egocAmount: Double
    public let usdValue: Double
    public let payment: String
    public let depositAddress: String?
    public let payAmount: Double?
    public let payCoin: String?

    public init?(file: URL) {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ego_presale"] as? Bool == true, let id = json["id"] as? String else { return nil }
        let allocation = json["allocation"] as? [String: Any] ?? [:]
        let pay = json["payment"] as? [String: Any] ?? [:]
        self.id = id
        self.file = file
        issuedAt = Date(timeIntervalSince1970: (json["issued_at"] as? NSNumber)?.doubleValue ?? 0)
        egocAmount = (allocation["egoc_amount"] as? NSNumber)?.doubleValue ?? 0
        usdValue = (allocation["usd_value"] as? NSNumber)?.doubleValue ?? 0
        payCoin = pay["coin"] as? String
        payAmount = (pay["amount"] as? NSNumber)?.doubleValue
        depositAddress = pay["deposit_address"] as? String
        payment = pay["method"] as? String == "stripe" ? "Card (Stripe)" : "\(payAmount.map { String($0) } ?? "") \(payCoin ?? "")"
    }

    /// The pre-sale folder in the app's documents, also reachable from the Files app.
    public static var folder: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pre-sale IOUs", isDirectory: true)
    }

    public static func save(_ data: Data) throws -> PresaleIOU {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = json?["id"] as? String ?? UUID().uuidString
        let pretty = try JSONSerialization.data(withJSONObject: json ?? [:], options: [.prettyPrinted, .sortedKeys])
        let file = folder.appendingPathComponent("ego-presale-iou-\(id).json")
        try pretty.write(to: file, options: .atomic)
        guard let iou = PresaleIOU(file: file) else { throw Presale.Failure.library("The IOU file couldn't be read back.") }
        return iou
    }

    public static func all() -> [PresaleIOU] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap(PresaleIOU.init(file:)).sorted { $0.issuedAt > $1.issuedAt }
    }
}

extension EgoAddress {
    /// The mainnet address (chain 0, "ego"), which pre-sale IOUs record.
    public static func mainnet(publicKey: [UInt8]) -> String {
        address(publicKey: publicKey, chainId: 0, hrp: "ego")
    }
}
