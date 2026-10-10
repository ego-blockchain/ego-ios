import EgoKit
import Foundation
import Network
import SwiftUI

enum WalletError: LocalizedError {
    case locked
    case offline

    var errorDescription: String? {
        switch self {
        case .locked: return "Unlock your wallet first."
        case .offline: return "You're offline. Connect to the internet and try again."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case onboarding
        case locked
        case ready
    }

    @Published var phase: Phase
    @Published var address = ""
    @Published var balance: UInt64?
    /// EGUSD credits (cents). Nil until a gateway that knows them answers.
    @Published var credits: UInt64?
    @Published var history: [HistoryItem] = []
    /// The gateway returns the newest transactions up to a limit, with no way
    /// to skip ahead, so older pages are reached by asking for more.
    @Published private(set) var historyLimit = AppModel.historyStep
    static let historyStep = 50
    static let historyMax = 500

    /// Whether the gateway may have transactions older than the ones loaded.
    var mayHaveOlderHistory: Bool {
        history.count >= historyLimit && historyLimit < AppModel.historyMax
    }
    @Published var gatewayHost: String?
    @Published var problem: String?
    @Published var seedMissing = false
    @Published var refreshing = false
    @Published private(set) var online = true

    private(set) var key: EgoKey?
    let vault = SeedVault()
    let directory: GatewayDirectory
    private let nearby: LocalGatewayBrowser
    private let pathMonitor = NWPathMonitor()
    private var pathSignature = ""

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = GatewayDirectory(store: FileGatewayStore(url: support.appendingPathComponent("gateways.json")))
        self.directory = directory
        nearby = LocalGatewayBrowser { gateways in
            Task { await directory.setLocal(gateways) }
        }
        if let stored = vault.storedAddress {
            address = stored
            phase = .locked
        } else {
            phase = .onboarding
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let signature = "\(online)|" + path.availableInterfaces.map { "\($0.type):\($0.name)" }.joined(separator: ",")
            Task { @MainActor [weak self] in
                self?.pathChanged(online: online, signature: signature)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.egoblockchain.wallet.path"))
        nearby.start()
    }

    private func pathChanged(online: Bool, signature: String) {
        let wasOnline = self.online
        let changed = signature != pathSignature
        pathSignature = signature
        self.online = online
        guard online, changed else { return }
        nearby.restart()
        let directory = self.directory
        Task {
            await directory.networkChanged()
            if !wasOnline && phase == .ready {
                await refresh()
            }
        }
    }

    func gateway() async throws -> GatewayClient {
        let client = try await directory.client()
        gatewayHost = client.gateway.endpoint.host
        return client
    }

    func perform<T>(_ work: (GatewayClient) async throws -> T) async throws -> T {
        guard online else { throw WalletError.offline }
        let client = try await gateway()
        do {
            return try await work(client)
        } catch GatewayError.rpc(AppModel.notHere, let message) {
            // An older Ego Desktop may not have this method yet. Ask other
            // gateways rather than failing, without leaving this one.
            for other in await directory.known.prefix(AppModel.notHereTries)
            where other.announcement.endpoint != client.gateway.endpoint.absoluteString {
                guard let gateway = other.announcement.gateway else { continue }
                if let answer = try? await work(GatewayClient(gateway: gateway, timeout: 8)) {
                    return answer
                }
            }
            throw GatewayError.rpc(AppModel.notHere, message)
        } catch GatewayError.rpc(let code, let message) {
            throw GatewayError.rpc(code, message)
        } catch {
            guard online else { throw WalletError.offline }
            await directory.reportFailure()
            return try await work(try await gateway())
        }
    }

    func finishSetup(with key: EgoKey) throws {
        try vault.store(seed: key.seed, address: key.address)
        self.key = key
        address = key.address
        phase = .ready
        Task { await refresh() }
    }

    func unlock() async {
        do {
            let seed = try await vault.readSeed(reason: "Unlock your Ego wallet")
            key = try EgoKey(seed: seed)
            phase = .ready
            problem = nil
            await refresh()
        } catch VaultError.cancelled {
            problem = nil
        } catch VaultError.missing {
            seedMissing = true
            problem = message(for: VaultError.missing)
        } catch {
            problem = message(for: error)
        }
    }

    func revealPhrase() async throws -> [String] {
        let reason = "Show your recovery phrase"
        let context = try await vault.authenticate(reason: reason)
        let seed = try await vault.readSeed(reason: reason, context: context)
        return Mnemonic.words(for: seed)
    }

    /// Removes the wallet from this iPhone once its owner confirms with Face ID.
    func logOut() async throws {
        _ = try await vault.authenticate(reason: "Log out of Ego Wallet on this iPhone")
        deleteWallet()
    }

    func lock() {
        guard vault.storedAddress != nil else { return }
        key = nil
        phase = .locked
    }

    func refresh() async {
        guard !address.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        let address = self.address
        do {
            balance = try await perform { try await $0.balance(of: address).uegoc }
            let limit = historyLimit
            history = try await perform { try await $0.history(of: address, limit: limit) }
            credits = try? await perform { try await $0.credits(of: address).credits }
            problem = nil
        } catch {
            problem = message(for: error)
        }
    }

    func networkFee() async -> UInt64? {
        let address = self.address
        return try? await perform { try await $0.nonce(of: address).feeUegoc }
    }

    func send(to recipient: String, amount: UInt64, memo: String) async throws -> String {
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try Transactions.transfer(key: key, to: recipient, amount: amount, nonce: info.next, fee: info.feeUegoc, memo: memo)
        return try await submit(tx)
    }

    /// The EGOC price validators will check a mint against, in µUSD.
    func egocPriceMicroUsd() async throws -> UInt64 {
        EGUSD.priceMicroUsd(try await perform { try await $0.egocPriceUsd() })
    }

    /// Burns `amount` µEGOC for EGUSD at the current price, like Convert in Ego Desktop.
    func convertToEGUSD(amount: UInt64, priceMicroUsd: UInt64) async throws -> String {
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try Transactions.creditsMint(key: key, amount: amount, priceMicroUsd: priceMicroUsd, nonce: info.next, fee: info.feeUegoc)
        return try await submit(tx)
    }

    func payEGUSD(to recipient: String, credits: UInt64) async throws -> String {
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try Transactions.creditsPay(key: key, to: recipient, credits: credits, nonce: info.next, fee: info.feeUegoc)
        return try await submit(tx)
    }

    /// Sends a signed transaction. If the gateway errors after accepting it,
    /// checks whether it landed anyway before reporting a failure.
    private func submit(_ tx: SignedTransaction) async throws -> String {
        var hash = tx.hash
        do {
            hash = try await perform { try await $0.submit(tx) }.txHash
        } catch {
            let submitted = tx.hash
            let landed = try? await perform({ try await $0.isConfirmed(hash: submitted) })
            guard landed == true else { throw error }
        }
        Task { await refresh() }
        return hash
    }

    enum NodeLookup {
        case found(NodeEarnings)
        case notFound
        case unreachable(String)
    }

    /// The Earnings page of the Ego Desktop that uses this wallet, asked
    /// directly from that computer. Other gateways can't answer it.
    func myNodeEarnings() async -> NodeLookup {
        guard let key else { return .unreachable(message(for: WalletError.locked)) }
        var own = await directory.gateways(runBy: key.address)
        if own.isEmpty, let more = try? await perform({ try await $0.gatewayList() }) {
            await directory.merge(more)
            own = await directory.gateways(runBy: key.address)
        }
        guard !own.isEmpty else { return .notFound }
        var problem = ""
        for gateway in own.prefix(3) {
            do {
                return .found(try await GatewayClient(gateway: gateway, timeout: 8).nodeEarnings(key: key))
            } catch {
                problem = message(for: error)
            }
        }
        return .unreachable(problem)
    }

    func rewards() async throws -> RewardsSummary {
        let address = self.address
        return try await perform { try await $0.rewards(of: address) }
    }

    func loadOlderHistory() async {
        guard mayHaveOlderHistory else { return }
        historyLimit = min(historyLimit + AppModel.historyStep, AppModel.historyMax)
        await refresh()
    }

    /// JSON-RPC "method not found", what a gateway answers for a method it's too old to have.
    static let notHere = -32601
    static let notHereTries = 4

    func deleteWallet() {
        vault.delete()
        key = nil
        address = ""
        balance = nil
        history = []
        historyLimit = AppModel.historyStep
        credits = nil
        problem = nil
        seedMissing = false
        phase = .onboarding
    }

    func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription {
            return text
        }
        return error.localizedDescription
    }
}
