import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(EgoWalletCore)
import EgoWalletCore
#endif

/// A coin on another chain, held at an address derived from the Ego seed the
/// same way Ego Desktop derives it (ego-wallet-core does the derivation).
public struct ExternalAsset: Identifiable, Hashable, Sendable {
    /// What's held: "BTC", "ETH", "USDT"…
    public let asset: String
    public let name: String
    /// The chain it lives on: "BTC", "ETH" for USDT and USDC…
    public let chain: String
    public let address: String
    public let addressType: String
    public let explorerPrefix: String
    /// The token contract, for tokens such as USDT on Ethereum.
    public let contract: String?
    public let decimals: Int

    public var id: String { asset }
    public var explorerURL: URL? { URL(string: explorerPrefix + address) }
    public var networkLabel: String {
        contract == nil ? name : "\(name) on \(ExternalAsset.chainNames[chain] ?? chain)"
    }

    static let chainNames = ["ETH": "Ethereum", "BNB": "BNB Chain"]
    static let networks = [
        "BTC": "Bitcoin", "ETH": "Ethereum", "BNB": "BNB Chain (BEP-20)", "SOL": "Solana", "ADA": "Cardano",
        "XRP": "the XRP Ledger", "TRX": "Tron", "LTC": "Litecoin", "DOGE": "Dogecoin",
    ]

    /// The network to name when warning people where to send from.
    public static func networkName(_ chain: String) -> String { networks[chain] ?? chain }
    static let decimalsByChain = ["BTC": 8, "LTC": 8, "DOGE": 8, "ETH": 18, "BNB": 18, "SOL": 9, "ADA": 6, "XRP": 6, "TRX": 6]
}

public enum ExternalWalletError: Error, Equatable, LocalizedError {
    case unavailable
    case derivation(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Other coins aren't available in this build."
        case .derivation(let why): return "Couldn't work out your other addresses: \(why)"
        }
    }
}

public enum ExternalWallet {
    struct Derived: Decodable {
        let chain: String
        let symbol: String
        let address: String
        let addressType: String
        let explorerPrefix: String

        enum CodingKeys: String, CodingKey {
            case chain, symbol, address
            case addressType = "address_type"
            case explorerPrefix = "explorer_prefix"
        }
    }

    /// Every coin Ego Desktop's wallet lists, in its order.
    public static func assets(seed: [UInt8]) throws -> [ExternalAsset] {
        try assets(from: derive(seed: seed))
    }

    static func assets(from derived: [Derived]) -> [ExternalAsset] {
        var list = derived.map {
            ExternalAsset(
                asset: $0.symbol, name: $0.chain, chain: $0.symbol, address: $0.address,
                addressType: $0.addressType, explorerPrefix: $0.explorerPrefix,
                contract: nil, decimals: ExternalAsset.decimalsByChain[$0.symbol] ?? 8
            )
        }
        if let eth = derived.first(where: { $0.symbol == "ETH" }) {
            for (asset, contract) in [("USDT", "0xdAC17F958D2ee523a2206206994597C13D831ec7"), ("USDC", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")] {
                list.append(ExternalAsset(
                    asset: asset, name: asset, chain: "ETH", address: eth.address,
                    addressType: "ERC-20", explorerPrefix: eth.explorerPrefix,
                    contract: contract, decimals: 6
                ))
            }
        }
        return list
    }

    static func derive(seed: [UInt8]) throws -> [Derived] {
        #if canImport(EgoWalletCore)
        let json: String = seed.withUnsafeBufferPointer { buffer in
            guard let raw = ego_wallet_addresses(buffer.baseAddress, buffer.count) else { return "" }
            defer { ego_wallet_string_free(raw) }
            return String(cString: raw)
        }
        let data = Data(json.utf8)
        if let list = try? JSONDecoder().decode([Derived].self, from: data) { return list }
        struct Failure: Decodable { let error: String }
        throw ExternalWalletError.derivation((try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "no answer")
        #else
        throw ExternalWalletError.unavailable
        #endif
    }
}

/// A balance in the asset's smallest unit, kept as a decimal string because
/// wei can exceed 64 bits.
public struct ExternalBalance: Equatable, Sendable {
    public let units: String
    public let decimals: Int

    public var isZero: Bool { units.allSatisfy { $0 == "0" } }

    /// "0.012345", trimmed to `maxDecimals` without rounding up.
    public func formatted(maxDecimals: Int = 6) -> String {
        BigUnits.format(units, decimals: decimals, maxDecimals: maxDecimals)
    }
}

enum BigUnits {
    /// "0x1bc16d674ec80000" → "2000000000000000000".
    static func decimal(fromHex hex: String) -> String? {
        var digits = Substring(hex.lowercased())
        if digits.hasPrefix("0x") { digits = digits.dropFirst(2) }
        if digits.isEmpty { return "0" }
        var result: [UInt8] = [0]  // base-10 digits, least significant first
        for c in digits {
            guard let nibble = c.hexDigitValue else { return nil }
            var carry = nibble
            for i in result.indices {
                let v = Int(result[i]) * 16 + carry
                result[i] = UInt8(v % 10)
                carry = v / 10
            }
            while carry > 0 {
                result.append(UInt8(carry % 10))
                carry /= 10
            }
        }
        while result.count > 1 && result.last == 0 { result.removeLast() }
        return String(result.reversed().map { Character(String($0)) })
    }

    static func format(_ units: String, decimals: Int, maxDecimals: Int) -> String {
        var digits = String(units.drop { $0 == "0" })
        if digits.isEmpty { digits = "0" }
        if digits.count <= decimals {
            digits = String(repeating: "0", count: decimals - digits.count + 1) + digits
        }
        let split = digits.index(digits.endIndex, offsetBy: -decimals)
        let whole = digits[..<split]
        var fraction = String(digits[split...].prefix(maxDecimals))
        while fraction.last == "0" { fraction.removeLast() }
        while fraction.count < min(2, maxDecimals) { fraction += "0" }
        return fraction.isEmpty ? String(whole) : "\(whole).\(fraction)"
    }
}

/// Balances from the same public services Ego Desktop asks.
public enum ExternalBalances {
    static let evmNodes = [
        "ETH": ["https://eth.llamarpc.com", "https://ethereum-rpc.publicnode.com", "https://eth.drpc.org"],
        "BNB": ["https://bsc-dataseed.binance.org", "https://bsc-rpc.publicnode.com", "https://bsc.drpc.org"],
    ]

    public static func balance(of asset: ExternalAsset) async throws -> ExternalBalance {
        let units: String
        switch asset.chain {
        case "ETH", "BNB":
            if let contract = asset.contract {
                let data = "0x70a08231" + String(repeating: "0", count: 24) + asset.address.dropFirst(2).lowercased()
                units = try await evmHex(asset.chain, "eth_call", [["to": contract, "data": data], "latest"])
            } else {
                units = try await evmHex(asset.chain, "eth_getBalance", [asset.address, "latest"])
            }
        case "BTC":
            let json = try await getJSON("https://blockstream.info/api/address/\(asset.address)")
            let stats = json["chain_stats"] as? [String: Any]
            let funded = (stats?["funded_txo_sum"] as? NSNumber)?.uint64Value ?? 0
            let spent = (stats?["spent_txo_sum"] as? NSNumber)?.uint64Value ?? 0
            units = String(funded >= spent ? funded - spent : 0)
        case "LTC", "DOGE":
            let json = try await getJSON("https://api.blockcypher.com/v1/\(asset.chain.lowercased())/main/addrs/\(asset.address)/balance")
            units = String((json["balance"] as? NSNumber)?.uint64Value ?? 0)
        case "SOL":
            let json = try await postJSON("https://api.mainnet-beta.solana.com", ["jsonrpc": "2.0", "id": 1, "method": "getBalance", "params": [asset.address]])
            units = String(((json["result"] as? [String: Any])?["value"] as? NSNumber)?.uint64Value ?? 0)
        case "XRP":
            let json = try await postJSON("https://xrplcluster.com", ["method": "account_info", "params": [["account": asset.address, "ledger_index": "validated"]]])
            let result = json["result"] as? [String: Any]
            if result?["error"] as? String == "actNotFound" {
                units = "0"  // An XRP account exists only once it's been funded.
            } else {
                units = ((result?["account_data"] as? [String: Any])?["Balance"] as? String) ?? "0"
            }
        case "TRX":
            let json = try await getJSON("https://api.trongrid.io/v1/accounts/\(asset.address)")
            let first = (json["data"] as? [[String: Any]])?.first
            units = String((first?["balance"] as? NSNumber)?.uint64Value ?? 0)
        case "ADA":
            // Koios only takes address_info as a POST now; the GET form answers 404.
            var request = URLRequest(url: URL(string: "https://api.koios.rest/api/v1/address_info")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["_addresses": [asset.address]])
            let data = try await fetch(request)
            let first = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first
            units = (first?["balance"] as? String) ?? "0"
        default:
            throw GatewayError.badResponse
        }
        guard units.allSatisfy(\.isNumber) else { throw GatewayError.badResponse }
        return ExternalBalance(units: units, decimals: asset.decimals)
    }

    static func evmHex(_ chain: String, _ method: String, _ params: [Any]) async throws -> String {
        var lastError: Error = GatewayError.badResponse
        for node in evmNodes[chain] ?? [] {
            do {
                let json = try await postJSON(node, ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
                if let hex = json["result"] as? String, let units = BigUnits.decimal(fromHex: hex) { return units }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func getJSON(_ url: String) async throws -> [String: Any] {
        guard let url = URL(string: url) else { throw GatewayError.badResponse }
        return try object(try await fetch(URLRequest(url: url)))
    }

    static func postJSON(_ url: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: url) else { throw GatewayError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try object(try await fetch(request))
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GatewayError.badResponse }
        return json
    }

    static func fetch(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
            throw GatewayError.unreachable("The \(request.url?.host ?? "balance") service didn't answer.")
        }
        return data
    }
}

extension BigUnits {
    /// Compares two non-negative decimal strings.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = String(a.drop { $0 == "0" }), y = String(b.drop { $0 == "0" })
        if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }

    /// Adds two non-negative decimal strings.
    static func add(_ a: String, _ b: String) -> String {
        let x = Array(a.reversed()), y = Array(b.reversed())
        var out: [Character] = []
        var carry = 0
        for i in 0..<max(x.count, y.count) {
            let d = (i < x.count ? Int(String(x[i]))! : 0) + (i < y.count ? Int(String(y[i]))! : 0) + carry
            out.append(Character(String(d % 10)))
            carry = d / 10
        }
        if carry > 0 { out.append(Character(String(carry))) }
        let s = String(out.reversed().drop { $0 == "0" })
        return s.isEmpty ? "0" : s
    }
}

/// A transfer signed and ready to broadcast, so the review shows exactly
/// what will be sent.
public struct PreparedTransfer: Equatable, Sendable {
    public let asset: ExternalAsset
    public let to: String
    public let raw: String
    public let hash: String
    /// In the asset's units.
    public let amountUnits: String
    /// In the chain's native coin's units (wei).
    public let feeUnits: String
    public let feeDecimals: Int
    public let feeSymbol: String

    public var amountText: String { BigUnits.format(amountUnits, decimals: asset.decimals, maxDecimals: asset.decimals) }
    public var feeText: String { BigUnits.format(feeUnits, decimals: feeDecimals, maxDecimals: 8) }
}

public enum ExternalSendError: Error, Equatable, LocalizedError {
    case notYet(String)
    case badAddress(String)
    case insufficient(String)
    case signing(String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .notYet(let asset): return "Sending \(asset) from the phone isn't ready yet. For now, send it from Ego Desktop."
        case .badAddress(let network): return "That isn't a \(network) address."
        case .insufficient(let what): return what
        case .signing(let why): return why
        case .rejected(let why): return "The network refused the transaction: \(why)"
        }
    }
}

public enum ExternalSend {
    /// Chains the phone can send on so far.
    public static func canSend(_ asset: ExternalAsset) -> Bool {
        ["ETH", "BNB", "BTC", "LTC"].contains(asset.chain)
    }

    /// Esplora APIs for coins and broadcasting, as on Ego Desktop's explorer links.
    static let esplora = ["BTC": "https://blockstream.info/api", "LTC": "https://litecoinspace.org/api"]

    public static func isValidAddress(_ text: String, for asset: ExternalAsset) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch asset.chain {
        case "ETH", "BNB":
            return t.count == 42 && t.hasPrefix("0x") && t.dropFirst(2).allSatisfy(\.isHexDigit)
        case "BTC":
            // The library checks the checksum and type before signing.
            return (25...90).contains(t.count) && (t.lowercased().hasPrefix("bc1") || t.hasPrefix("1") || t.hasPrefix("3"))
        case "LTC":
            return (25...90).contains(t.count) && (t.lowercased().hasPrefix("ltc1") || t.hasPrefix("L") || t.hasPrefix("M") || t.hasPrefix("3"))
        default:
            return !t.isEmpty
        }
    }

    public static func explorerTxURL(_ asset: ExternalAsset, hash: String) -> URL? {
        let prefix = [
            "ETH": "https://etherscan.io/tx/", "BNB": "https://bscscan.com/tx/",
            "BTC": "https://blockstream.info/tx/", "LTC": "https://litecoinspace.org/tx/",
        ][asset.chain]
        return prefix.flatMap { URL(string: $0 + hash) }
    }

    /// Fetches the nonce and gas price, checks the balances and signs, without sending.
    public static func prepare(
        _ asset: ExternalAsset, seed: [UInt8], to: String, amount: String,
        balance: ExternalBalance?, nativeBalance: ExternalBalance?
    ) async throws -> PreparedTransfer {
        guard canSend(asset) else { throw ExternalSendError.notYet(asset.asset) }
        let recipient = to.trimmingCharacters(in: .whitespaces)
        guard isValidAddress(recipient, for: asset) else { throw ExternalSendError.badAddress(ExternalAsset.networkName(asset.chain)) }
        if let base = esplora[asset.chain] {
            return try await prepareUTXO(asset, base: base, seed: seed, to: recipient, amount: amount, balance: balance)
        }
        let nonceHex = try await ExternalBalances.evmHex(asset.chain, "eth_getTransactionCount", [asset.address, "pending"])
        let gasPrice = try await ExternalBalances.evmHex(asset.chain, "eth_gasPrice", [])
        var request: [String: Any] = [
            "chain": asset.chain, "nonce": UInt64(nonceHex) ?? 0, "gas_price": gasPrice,
            "to": recipient, "amount": amount.trimmingCharacters(in: .whitespaces), "decimals": asset.decimals,
        ]
        if let contract = asset.contract { request["contract"] = contract }
        let signed = try sign(seed: seed, request: request, with: ego_wallet_sign_evm)
        let native = asset.contract == nil ? asset.asset : asset.chain
        let prepared = PreparedTransfer(
            asset: asset, to: recipient, raw: signed.raw, hash: signed.hash,
            amountUnits: signed.amountUnits, feeUnits: signed.fee, feeDecimals: 18, feeSymbol: native
        )
        try checkFunds(prepared, balance: balance, nativeBalance: nativeBalance)
        return prepared
    }

    static func checkFunds(_ p: PreparedTransfer, balance: ExternalBalance?, nativeBalance: ExternalBalance?) throws {
        if p.asset.contract == nil {
            if let balance, BigUnits.compare(BigUnits.add(p.amountUnits, p.feeUnits), balance.units) == .orderedDescending {
                throw ExternalSendError.insufficient("That's more than your \(p.asset.asset) after the network fee of \(BigUnits.format(p.feeUnits, decimals: 18, maxDecimals: 8)) \(p.feeSymbol).")
            }
        } else {
            if let balance, BigUnits.compare(p.amountUnits, balance.units) == .orderedDescending {
                throw ExternalSendError.insufficient("You have \(balance.formatted()) \(p.asset.asset).")
            }
            if let nativeBalance, BigUnits.compare(p.feeUnits, nativeBalance.units) == .orderedDescending {
                throw ExternalSendError.insufficient("Sending \(p.asset.asset) costs a network fee of about \(BigUnits.format(p.feeUnits, decimals: 18, maxDecimals: 8)) \(p.feeSymbol), and you have \(nativeBalance.formatted(maxDecimals: 8)) \(p.feeSymbol).")
            }
        }
    }

    static func prepareUTXO(_ asset: ExternalAsset, base: String, seed: [UInt8], to: String, amount: String, balance: ExternalBalance?) async throws -> PreparedTransfer {
        let coinsData = try await ExternalBalances.fetch(URLRequest(url: URL(string: "\(base)/address/\(asset.address)/utxo")!))
        let coins = (try JSONSerialization.jsonObject(with: coinsData) as? [[String: Any]] ?? []).compactMap { c -> [String: Any]? in
            guard let txid = c["txid"] as? String, let vout = c["vout"] as? Int, let value = (c["value"] as? NSNumber)?.uint64Value else { return nil }
            return ["txid": txid, "vout": vout, "value": value]
        }
        guard !coins.isEmpty else { throw ExternalSendError.insufficient("This address has no \(asset.asset) to send yet.") }
        let rate = try await feeRate(base)
        let signed = try sign(seed: seed, request: [
            "chain": asset.chain, "to": to, "amount": amount.trimmingCharacters(in: .whitespaces),
            "fee_rate": rate, "utxos": coins,
        ], with: ego_wallet_sign_utxo)
        let prepared = PreparedTransfer(
            asset: asset, to: to, raw: signed.raw, hash: signed.hash,
            amountUnits: signed.amountUnits, feeUnits: signed.fee, feeDecimals: 8, feeSymbol: asset.asset
        )
        try checkFunds(prepared, balance: balance, nativeBalance: balance)
        return prepared
    }

    /// The network's estimate for confirming within about six blocks, never below 2 sat/vB.
    /// litecoinspace runs mempool.space, which has no /fee-estimates; its half-hour rate is the same idea.
    static func feeRate(_ base: String) async throws -> UInt64 {
        let rate: NSNumber?
        if base.contains("litecoinspace") {
            rate = try await ExternalBalances.getJSON("\(base)/v1/fees/recommended")["halfHourFee"] as? NSNumber
        } else {
            let estimates = try await ExternalBalances.getJSON("\(base)/fee-estimates")
            rate = (estimates["6"] ?? estimates["3"] ?? estimates["2"]) as? NSNumber
        }
        return max(2, UInt64((rate?.doubleValue ?? 10).rounded(.up)))
    }

    public static func broadcast(_ p: PreparedTransfer) async throws -> String {
        if let base = esplora[p.asset.chain] {
            var request = URLRequest(url: URL(string: "\(base)/tx")!)
            request.httpMethod = "POST"
            request.httpBody = Data(p.raw.utf8)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (response as? HTTPURLResponse)?.statusCode == 200, text.count == 64 else {
                throw ExternalSendError.rejected(text.isEmpty ? "no answer" : text)
            }
            return text
        }
        var lastError: Error = ExternalSendError.rejected("no node answered")
        for node in ExternalBalances.evmNodes[p.asset.chain] ?? [] {
            do {
                let json = try await ExternalBalances.postJSON(node, ["jsonrpc": "2.0", "id": 1, "method": "eth_sendRawTransaction", "params": [p.raw]])
                if let hash = json["result"] as? String { return hash }
                if let message = (json["error"] as? [String: Any])?["message"] as? String {
                    // Another node already has it: that's a success.
                    if message.lowercased().contains("already known") { return p.hash }
                    lastError = ExternalSendError.rejected(message)
                    if message.lowercased().contains("insufficient funds") || message.lowercased().contains("nonce") { break }
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    struct Signed: Decodable {
        let raw: String
        let hash: String
        let fee: String
        let amountUnits: String
        enum CodingKeys: String, CodingKey { case raw, hash, fee, amountUnits = "amount_units" }
    }

    typealias Signer = (UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

    static func sign(seed: [UInt8], request: [String: Any], with signer: Signer) throws -> Signed {
        #if canImport(EgoWalletCore)
        let body = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let json: String = seed.withUnsafeBufferPointer { buffer in
            body.withCString { cBody in
                guard let raw = signer(buffer.baseAddress, buffer.count, cBody) else { return "" }
                defer { ego_wallet_string_free(raw) }
                return String(cString: raw)
            }
        }
        let data = Data(json.utf8)
        if let signed = try? JSONDecoder().decode(Signed.self, from: data) { return signed }
        struct Failure: Decodable { let error: String }
        throw ExternalSendError.signing((try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "Couldn't sign.")
        #else
        throw ExternalWalletError.unavailable
        #endif
    }
}
