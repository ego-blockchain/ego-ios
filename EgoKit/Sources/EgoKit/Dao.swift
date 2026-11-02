import Foundation

/// DAO voting as the chain runs it: proposals, stake votes, knowledge votes whose
/// answers stay hidden until voting ends, and reports against spam proposers.
/// Every operation is a zero-amount transaction to the sender itself, whose memo
/// commits to its JSON body with BLAKE3, as Ego Desktop's dao_chain does.
public enum Dao {
    static let bodyDomain = "ego/dao/body/v1:"
    static let answersDomain = "ego/dao/answers/v1:"
    static let voteAnswersDomain = "ego/dao/vote-answers/v1:"
    static let idDomain = "ego/dao/id/v1:"

    public static let propose = "dao_propose"
    public static let vote = "dao_vote"
    public static let know = "dao_know"
    public static let reveal = "dao_reveal"
    public static let withdraw = "dao_withdraw"
    public static let knowReveal = "dao_know_reveal"
    public static let report = "dao_report"
    public static let opTypes = [propose, vote, know, reveal, withdraw, knowReveal, report]

    /// How long after voting ends the hidden answers can still be revealed.
    public static let revealWindow: Int64 = 7 * 86_400

    public static func memo(for txType: String, callArgs: String) -> String? {
        guard opTypes.contains(txType) else { return nil }
        let op = txType.dropFirst("dao_".count)
        return "dao:\(op):" + Blake3.hex(bodyDomain + callArgs)
    }

    /// A proposal's id comes from the hash of the transaction that created it.
    public static func proposalId(txHash: String) -> String {
        "dao" + Blake3.hex(idDomain + txHash).prefix(16)
    }

    /// What a proposal creator commits to: the right answers to its questions.
    public static func answersCommit(salt: String, answers: [UInt8]) -> String {
        Blake3.hex(Array((answersDomain + salt + ":").utf8) + answers)
    }

    /// What a knowledge voter commits to: their answers, bound to the proposal and to them.
    public static func voteCommit(id: String, voter: String, salt: String, answers: [UInt8]) -> String {
        Blake3.hex(Array((voteAnswersDomain + id + ":" + voter + ":" + salt + ":").utf8) + answers)
    }

    public static func newSalt() -> String {
        Hex.encode(SecureRandom.bytes(32))
    }

    // MARK: Bodies

    public struct Question: Codable, Equatable, Sendable {
        public let question: String
        public let options: [String]
        public init(question: String, options: [String]) { self.question = question; self.options = options }
    }

    public struct ProposeBody: Encodable {
        public let title: String
        public let description: String
        public let kind: String
        public let options: [String]
        public let durationDays: UInt32
        public let questions: [Question]
        public let answersCommit: String

        enum CodingKeys: String, CodingKey {
            case title, description, kind, options, questions
            case durationDays = "duration_days"
            case answersCommit = "answers_commit"
        }

        public init(title: String, description: String, kind: String, options: [String], durationDays: UInt32,
                    questions: [Question] = [], answersCommit: String = "") {
            self.title = title; self.description = description; self.kind = kind; self.options = options
            self.durationDays = durationDays; self.questions = questions; self.answersCommit = answersCommit
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encode(description, forKey: .description)
            try c.encode(kind, forKey: .kind)
            try c.encode(options, forKey: .options)
            try c.encode(durationDays, forKey: .durationDays)
            if !questions.isEmpty { try c.encode(questions, forKey: .questions) }
            if !answersCommit.isEmpty { try c.encode(answersCommit, forKey: .answersCommit) }
        }
    }

    public struct VoteBody: Encodable {
        public let id: String
        public let option: UInt32
        public init(id: String, option: UInt32) { self.id = id; self.option = option }
    }

    public struct KnowBody: Encodable {
        public let id: String
        public let option: UInt32
        public let commit: String
        public init(id: String, option: UInt32, commit: String) { self.id = id; self.option = option; self.commit = commit }
    }

    public struct RevealBody: Encodable {
        public let id: String
        public let salt: String
        public let answers: [UInt8]
        public init(id: String, salt: String, answers: [UInt8]) { self.id = id; self.salt = salt; self.answers = answers }
    }

    public struct WithdrawBody: Encodable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    public struct ReportBody: Encodable {
        public let target: String
        public init(target: String) { self.target = target }
    }

    /// The body as the memo commits to it. Keys are sorted so the same body always
    /// gives the same memo; the node reads any key order.
    public static func body<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func operation<T: Encodable>(
        key: EgoKey, txType: String, body: T, nonce: UInt64, fee: UInt64,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970), version: Int = 3
    ) throws -> SignedTransaction {
        let callArgs = try self.body(body)
        guard let memo = memo(for: txType, callArgs: callArgs) else { throw TransactionError.badRecipient }
        var tx = try Transactions.sign(key: key, to: key.address, amount: 0, nonce: nonce, fee: fee, memo: memo,
                                       txType: txType, timestamp: timestamp, version: version)
        tx.callArgs = callArgs
        return tx
    }

    /// A secret that has to be sent again after voting ends: the salt and the answers.
    public struct Secret: Codable, Equatable, Sendable {
        public let id: String
        public let salt: String
        public let answers: [UInt8]
        /// true: this wallet created the proposal and reveals the right answers.
        /// false: this wallet voted and reveals its own answers.
        public let isCreator: Bool
        public init(id: String, salt: String, answers: [UInt8], isCreator: Bool) {
            self.id = id; self.salt = salt; self.answers = answers; self.isCreator = isCreator
        }
    }

    // MARK: What a gateway answers

    public struct TestQuestion: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let question: String
        public let options: [String]
    }

    public struct Proposal: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let description: String
        public let kind: String
        public let options: [String]
        public let creator: String
        public let createdAt: Int64
        public let endsAt: Int64
        public let status: String
        public let hasKnowledgeTest: Bool
        public let questionCount: Int
        public let stakeVoteCount: Int
        public let knowledgeVoteCount: Int
        public let questions: [TestQuestion]?
        public let myStakeVote: Int?
        public let myKnowledgeVote: Int?
        public let myTestScore: Double?
        public let answersRevealed: Bool

        enum CodingKeys: String, CodingKey {
            case id, title, description, options, creator, status, questions
            case kind = "proposal_type"
            case createdAt = "created_at"
            case endsAt = "voting_ends_at"
            case hasKnowledgeTest = "has_knowledge_test"
            case questionCount = "question_count"
            case stakeVoteCount = "stake_vote_count"
            case knowledgeVoteCount = "knowledge_vote_count"
            case myStakeVote = "my_stake_vote"
            case myKnowledgeVote = "my_knowledge_vote"
            case myTestScore = "my_test_score"
            case answersRevealed = "answers_revealed"
        }

        public var isActive: Bool { status == "active" }
        public var hasVoted: Bool { myStakeVote != nil || myKnowledgeVote != nil }
    }

    public struct OptionResult: Decodable, Equatable, Sendable {
        public let option: String
        public let stakePower: Double
        public let knowledgePower: Double
        public let combinedPower: Double

        enum CodingKeys: String, CodingKey {
            case option
            case stakePower = "stake_power"
            case knowledgePower = "knowledge_power"
            case combinedPower = "combined_power"
        }
    }

    public struct Results: Decodable, Equatable, Sendable {
        public let options: [OptionResult]
        public let winningOptionIndex: Int?
        public let totalStakeVoters: Int
        public let totalKnowledgeVoters: Int
        public let totalStakedInVotes: UInt64
        public let quorumReached: Bool
        public let status: String

        enum CodingKeys: String, CodingKey {
            case options, status
            case winningOptionIndex = "winning_option_index"
            case totalStakeVoters = "total_stake_voters"
            case totalKnowledgeVoters = "total_knowledge_voters"
            case totalStakedInVotes = "total_staked_in_votes"
            case quorumReached = "quorum_reached"
        }
    }

    public struct Detail: Decodable, Equatable, Sendable {
        public let proposal: Proposal
        public let results: Results
    }

    public struct BanStatus: Decodable, Equatable, Sendable {
        public let target: String
        public let voteCount: Int
        public let threshold: Int
        public let banned: Bool
        public let myVote: Bool

        enum CodingKeys: String, CodingKey {
            case target, threshold, banned
            case voteCount = "vote_count"
            case myVote = "my_vote"
        }
    }

    public struct Limits: Decodable, Equatable, Sendable {
        public let active: Bool
        public let used: Int
        public let max: Int
        public let windowDays: Int
        public let resetsAt: Int64
        public let banned: Bool
        public let kinds: [String]
        public let minDays: Int
        public let maxDays: Int
        public let defaultDays: Int
        public let maxTitleBytes: Int
        public let maxDescriptionBytes: Int
        public let maxOptions: Int
        public let maxOptionBytes: Int
        public let maxQuestions: Int
        public let maxQuestionBytes: Int
        public let maxQuestionOptions: Int

        enum CodingKeys: String, CodingKey {
            case active, used, max, banned, kinds
            case windowDays = "window_days"
            case resetsAt = "resets_at"
            case minDays = "min_days"
            case maxDays = "max_days"
            case defaultDays = "default_days"
            case maxTitleBytes = "max_title_bytes"
            case maxDescriptionBytes = "max_description_bytes"
            case maxOptions = "max_options"
            case maxOptionBytes = "max_option_bytes"
            case maxQuestions = "max_questions"
            case maxQuestionBytes = "max_question_bytes"
            case maxQuestionOptions = "max_question_options"
        }

        public var left: Int { Swift.max(0, max - used) }
    }

    /// Whether this secret should be sent now. The creator reveals in the week after
    /// voting ends; a voter reveals once the creator's answers are on the chain, and
    /// has a week from then, so at most two weeks after voting ends.
    public static func revealDue(_ secret: Secret, proposal: Proposal, now: Int64) -> Bool {
        guard proposal.status != "withdrawn", now >= proposal.endsAt else { return false }
        if secret.isCreator { return !proposal.answersRevealed && now < proposal.endsAt + revealWindow }
        return proposal.answersRevealed && proposal.myTestScore == nil && now < proposal.endsAt + revealWindow * 2
    }

    /// Whether this secret can be forgotten: revealed already, or too late.
    public static func revealFinished(_ secret: Secret, proposal: Proposal?, now: Int64) -> Bool {
        guard let proposal else { return false }
        if proposal.status == "withdrawn" { return true }
        if secret.isCreator ? proposal.answersRevealed : proposal.myTestScore != nil { return true }
        return now >= proposal.endsAt + revealWindow * 2
    }
}

extension GatewayClient {
    /// Proposals, newest first. filter: "all", "active", "expired" or "withdrawn".
    public func daoProposals(filter: String = "all", voter: String) async throws -> [Dao.Proposal] {
        let list: [Dao.Proposal] = try await call("dao.list", ["filter": filter, "voter": voter])
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    public func daoProposal(_ id: String, voter: String) async throws -> Dao.Detail {
        try await call("dao.proposal", ["id": id, "voter": voter])
    }

    public func daoBanStatus(of target: String, viewer: String) async throws -> Dao.BanStatus {
        try await call("dao.banStatus", ["target": target, "viewer": viewer])
    }

    public func daoLimits(of address: String) async throws -> Dao.Limits {
        try await call("dao.limits", ["address": address])
    }
}
