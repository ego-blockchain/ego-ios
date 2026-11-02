import EgoKit
import Foundation

struct StakingPage: Hashable {}
struct GovernancePage: Hashable {}

enum GovernanceError: LocalizedError {
    case needStake
    case locked(until: Int64)
    case banned
    case rateLimited(resetsAt: Int64)

    var errorDescription: String? {
        switch self {
        case .needStake:
            return "Only staked EGOC can do this. Stake some EGOC first; it stays locked until the vote ends."
        case .locked(let until):
            return "A vote keeps your stake locked until \(Date(timeIntervalSince1970: TimeInterval(until)).formatted(date: .abbreviated, time: .shortened))."
        case .banned:
            return "Staked holders reported this wallet, so it can't create proposals for now."
        case .rateLimited(let at):
            return "You've used all your proposals for this month. The next one frees up \(Date(timeIntervalSince1970: TimeInterval(at)).formatted(date: .abbreviated, time: .omitted))."
        }
    }
}

/// Staking and DAO voting through a gateway. The phone signs every transaction itself;
/// the hidden answers of knowledge votes and of its own proposals stay on this iPhone
/// until they're revealed after voting ends.
extension AppModel {
    // MARK: Staking

    func stakingStatus() async throws -> Staking.Status {
        let address = self.address
        return try await perform { try await $0.stakingStatus(of: address) }
    }

    func stake(_ amount: UInt64, lockDays: UInt32) async throws {
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try Staking.stake(key: key, amount: amount, lockDays: lockDays, nonce: info.next, fee: info.feeUegoc,
                                   version: max(3, info.txVersion))
        _ = try await submit(tx)
    }

    func unstake(_ status: Staking.Status) async throws {
        guard let key else { throw WalletError.locked }
        guard status.canUnstake else { throw GovernanceError.locked(until: status.voteLockedUntil) }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try Staking.unstake(key: key, staked: status.staked, early: status.locked, nonce: info.next,
                                     fee: info.feeUegoc, version: max(3, info.txVersion))
        _ = try await submit(tx)
    }

    // MARK: Reading the DAO

    func daoProposals(filter: String = "all") async throws -> [Dao.Proposal] {
        let address = self.address
        return try await perform { try await $0.daoProposals(filter: filter, voter: address) }
    }

    func daoProposal(_ id: String) async throws -> Dao.Detail {
        let address = self.address
        return try await perform { try await $0.daoProposal(id, voter: address) }
    }

    func daoLimits() async throws -> Dao.Limits {
        let address = self.address
        return try await perform { try await $0.daoLimits(of: address) }
    }

    func daoBanStatus(of target: String) async throws -> Dao.BanStatus {
        let address = self.address
        return try await perform { try await $0.daoBanStatus(of: target, viewer: address) }
    }

    // MARK: Voting

    @discardableResult
    private func daoOperation<T: Encodable>(_ txType: String, _ body: T) async throws -> SignedTransaction {
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try Dao.operation(key: key, txType: txType, body: body, nonce: info.next, fee: info.feeUegoc,
                                   version: max(3, info.txVersion))
        _ = try await submit(tx)
        return tx
    }

    private func requireStake() async throws {
        if try await stakingStatus().staked == 0 { throw GovernanceError.needStake }
    }

    func stakeVote(_ proposal: Dao.Proposal, option: Int) async throws {
        try await requireStake()
        try await daoOperation(Dao.vote, Dao.VoteBody(id: proposal.id, option: UInt32(option)))
    }

    /// Votes with a knowledge test. The answers are sent only as a commitment now and
    /// revealed by this iPhone after the creator reveals the right ones.
    func knowledgeVote(_ proposal: Dao.Proposal, option: Int, answers: [Int]) async throws {
        let salt = Dao.newSalt()
        let bytes = answers.map { UInt8($0) }
        let commit = Dao.voteCommit(id: proposal.id, voter: address, salt: salt, answers: bytes)
        let secret = Dao.Secret(id: proposal.id, salt: salt, answers: bytes, isCreator: false)
        saveDaoSecret(secret)
        do {
            try await daoOperation(Dao.know, Dao.KnowBody(id: proposal.id, option: UInt32(option), commit: commit))
        } catch {
            forgetDaoSecret(secret)
            throw error
        }
    }

    /// Creates a proposal. `rightAnswers` holds the right option of each question; it stays
    /// hidden until voting ends, then this iPhone reveals it. Returns the proposal's id.
    func createProposal(title: String, description: String, kind: String, options: [String], days: UInt32,
                        questions: [Dao.Question], rightAnswers: [Int]) async throws -> String {
        let limits = try await daoLimits()
        if limits.banned { throw GovernanceError.banned }
        if limits.left == 0 { throw GovernanceError.rateLimited(resetsAt: limits.resetsAt) }
        let salt = Dao.newSalt()
        let answers = rightAnswers.map { UInt8($0) }
        let body = Dao.ProposeBody(title: title, description: description, kind: kind, options: options, durationDays: days,
                                   questions: questions, answersCommit: questions.isEmpty ? "" : Dao.answersCommit(salt: salt, answers: answers))
        guard let key else { throw WalletError.locked }
        let address = key.address
        let info = try await perform { try await $0.nonce(of: address) }
        let tx = try Dao.operation(key: key, txType: Dao.propose, body: body, nonce: info.next, fee: info.feeUegoc,
                                   version: max(3, info.txVersion))
        let id = Dao.proposalId(txHash: tx.hash)
        let secret = Dao.Secret(id: id, salt: salt, answers: answers, isCreator: true)
        if !questions.isEmpty { saveDaoSecret(secret) }
        do {
            _ = try await submit(tx)
        } catch {
            forgetDaoSecret(secret)
            throw error
        }
        return id
    }

    func withdrawProposal(_ proposal: Dao.Proposal) async throws {
        try await daoOperation(Dao.withdraw, Dao.WithdrawBody(id: proposal.id))
    }

    /// Reports a proposer for spam. Locks the reporter's stake for 30 days.
    func reportProposer(_ target: String) async throws {
        try await requireStake()
        try await daoOperation(Dao.report, Dao.ReportBody(target: target))
    }

    // MARK: Revealing hidden answers

    private var secretsKey: String { "dao.secrets.\(address)" }

    var daoSecrets: [Dao.Secret] {
        get {
            guard let data = UserDefaults.standard.data(forKey: secretsKey) else { return [] }
            return (try? JSONDecoder().decode([Dao.Secret].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: secretsKey)
        }
    }

    private func saveDaoSecret(_ secret: Dao.Secret) {
        daoSecrets = daoSecrets.filter { !($0.id == secret.id && $0.isCreator == secret.isCreator) } + [secret]
    }

    private func forgetDaoSecret(_ secret: Dao.Secret) {
        daoSecrets = daoSecrets.filter { $0 != secret }
    }

    /// Sends every reveal that is due and forgets the ones that are done. Returns how many went out.
    @discardableResult
    func sendDueDaoReveals() async -> Int {
        let now = Int64(Date().timeIntervalSince1970)
        var sent = 0
        for secret in daoSecrets {
            let proposal = try? await daoProposal(secret.id).proposal
            if Dao.revealFinished(secret, proposal: proposal, now: now) {
                forgetDaoSecret(secret)
                continue
            }
            guard let proposal, Dao.revealDue(secret, proposal: proposal, now: now) else { continue }
            let body = Dao.RevealBody(id: secret.id, salt: secret.salt, answers: secret.answers)
            if (try? await daoOperation(secret.isCreator ? Dao.reveal : Dao.knowReveal, body)) != nil {
                sent += 1
            }
        }
        return sent
    }
}
