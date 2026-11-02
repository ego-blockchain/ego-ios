import EgoKit
import Foundation

struct VaultPage: Hashable {}

enum VaultFlowError: LocalizedError {
    case noVault
    case nothingToSweep

    var errorDescription: String? {
        switch self {
        case .noVault: return "This wallet has no vault yet."
        case .nothingToSweep: return "There is nothing to sweep."
        }
    }
}

/// The wallet vault through a gateway: status, settings, waiting sends, freeze, sweep, and
/// approving another wallet's request when this iPhone is its second key.
extension AppModel {
    private var mineKey: String { "vault.mine.\(address)" }
    private var sentKey: String { "vault.sent.\(address)" }

    /// Waiting sends this iPhone started, so it can send them when their wait is over.
    var vaultMine: [String] {
        get { UserDefaults.standard.stringArray(forKey: mineKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: mineKey) }
    }

    private var vaultSent: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: sentKey) }
    }

    func vaultStatus() async throws -> Vault.Status {
        let address = self.address
        return try await perform { try await $0.vaultStatus(of: address) }
    }

    private func vaultOperation<T: Encodable>(_ txType: String, _ body: T) async throws -> String {
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try Vault.operation(key: key, txType: txType, body: body, nonce: info.next, fee: info.feeUegoc,
                                     version: max(3, info.txVersion))
        return try await submit(tx)
    }

    func saveVault(_ settings: Vault.Settings) async throws {
        _ = try await vaultOperation("vault_set", Vault.SetBody(settings: settings))
    }

    func freezeVault(owner: String? = nil) async throws {
        _ = try await vaultOperation("vault_freeze", Vault.OwnerBody(owner: owner ?? address))
    }

    func unfreezeVault() async throws {
        _ = try await vaultOperation("vault_unfreeze", Vault.EmptyBody())
    }

    func turnVaultOff() async throws {
        _ = try await vaultOperation("vault_off", Vault.EmptyBody())
    }

    func cancelInVault(owner: String? = nil, target: String) async throws {
        _ = try await vaultOperation("vault_cancel", Vault.CancelBody(owner: owner ?? address, target: target))
    }

    /// Starts a send that waits out the vault's delay. Returns how long it waits.
    func sendWithDelay(to recipient: String, amount: UInt64) async throws -> Int64 {
        let status = try await vaultStatus()
        guard let vault = status.vault else { throw VaultFlowError.noVault }
        let hash = try await vaultOperation("vault_queue", Vault.QueueBody(to: recipient, amount: amount))
        vaultMine = vaultMine + [Vault.queueId(txHash: hash)]
        return vault.settings.delay(for: amount)
    }

    /// Sends everything to the recovery address in one step. Works even while frozen.
    func sweepVault(to recovery: String) async throws -> String {
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let have = try await perform { try await $0.balance(of: address) }.uegoc
        guard have > info.feeUegoc else { throw VaultFlowError.nothingToSweep }
        let tx = try Transactions.transfer(key: key, to: recovery, amount: have - info.feeUegoc, nonce: info.next,
                                           fee: info.feeUegoc, memo: Vault.sweepMemo, version: max(3, info.txVersion))
        return try await submit(tx)
    }

    /// Sends this iPhone's waiting sends whose wait is over. Returns how many went out.
    @discardableResult
    func sendDueVaultSends(_ status: Vault.Status) async -> Int {
        guard let key, let vault = status.vault, !vault.frozen else { return 0 }
        let now = Date().timeIntervalSince1970
        let live = Set(vault.queue.map(\.id))
        vaultMine = vaultMine.filter { live.contains($0) }
        var sent = vaultSent.filter { now - $0.value < 86_400 }
        var count = 0
        for q in vault.queue where vaultMine.contains(q.id) && Double(q.at) <= now {
            if let last = sent[q.id], now - last < 600 { continue }
            do {
                let address = key.address
                let info = try await perform { try await $0.nonce(of: address) }
                let tx = try Transactions.transfer(key: key, to: q.to, amount: q.amount, nonce: info.next, fee: info.feeUegoc,
                                                   memo: Vault.execMemo(q.id), version: max(3, info.txVersion))
                _ = try await submit(tx, refreshAfter: false)
                sent[q.id] = now
                count += 1
            } catch {
                continue
            }
        }
        vaultSent = sent
        return count
    }

    /// Approves another wallet's request with this wallet's key, when this wallet is that vault's second key.
    func approveVaultRequest(_ request: Vault.ApprovalRequest) async throws -> String {
        guard let key else { throw WalletError.locked }
        let owner = request.from
        let theirs = try await perform { try await $0.vaultStatus(of: owner) }
        guard let secondKey = theirs.vault?.settings.secondKey, !secondKey.isEmpty else { throw VaultError.notSecondKey }
        return try Vault.approve(request, with: key, secondKey: secondKey)
    }
}
