import XCTest
@testable import EgoKit

/// The commitment values are pinned on both sides: Ego Desktop's phone_dao tests
/// assert the same strings, so a DAO transaction from the phone always matches
/// what the node checks.
final class DaoTests: XCTestCase {
    let id = "dao0123456789abcdef"

    func testBodiesAndCommitmentsMatchTheNode() throws {
        let vote = try Dao.body(Dao.VoteBody(id: id, option: 2))
        XCTAssertEqual(vote, #"{"id":"dao0123456789abcdef","option":2}"#)
        XCTAssertEqual(Dao.memo(for: Dao.vote, callArgs: vote), "dao:vote:92ef34a3cb53bf14d7f3f90430b3077795aa48b7b50ce49bcb9e4abd1001a640")
        XCTAssertEqual(Dao.proposalId(txHash: "0xabc123"), "daoa402c11f3ed2d394")
        XCTAssertEqual(Dao.answersCommit(salt: String(repeating: "a", count: 64), answers: [1, 0, 3]),
                       "0c9a6f058fe1d5569b31ad647926b791a725a6c4138ce45c1e1a400969be5fdb")
        XCTAssertEqual(Dao.voteCommit(id: id, voter: "egot1alice", salt: String(repeating: "b", count: 64), answers: [2, 1]),
                       "2812021084b55f67fe43e144e0ed51f01b3443498bd3859c639a2183f10a90a5")
        XCTAssertEqual(try Dao.body(Dao.RevealBody(id: id, salt: String(repeating: "c", count: 64), answers: [0, 1, 2])),
                       #"{"answers":[0,1,2],"id":"dao0123456789abcdef","salt":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}"#)
        XCTAssertNil(Dao.memo(for: "transfer", callArgs: vote))
    }

    func testAProposalWithoutQuestionsLeavesThemOut() throws {
        let plain = try Dao.body(Dao.ProposeBody(title: "T", description: "D", kind: "feature", options: ["Yes", "No"], durationDays: 7))
        XCTAssertFalse(plain.contains("questions"))
        XCTAssertFalse(plain.contains("answers_commit"))
        let tested = try Dao.body(Dao.ProposeBody(title: "T", description: "D", kind: "feature", options: ["Yes", "No"], durationDays: 7,
                                                  questions: [.init(question: "Q?", options: ["a", "b"])], answersCommit: "x"))
        XCTAssertTrue(tested.contains(#""duration_days":7"#))
        XCTAssertTrue(tested.contains(#""answers_commit":"x""#))
    }

    func testAnOperationIsAZeroSendToYourselfCommittingToItsBody() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 7, count: 32))
        let tx = try Dao.operation(key: key, txType: Dao.vote, body: Dao.VoteBody(id: id, option: 1), nonce: 4, fee: 1_000, timestamp: 1_800_000_000)
        XCTAssertEqual(tx.to, key.address)
        XCTAssertEqual(tx.amount, 0)
        XCTAssertEqual(tx.txType, "dao_vote")
        XCTAssertEqual(tx.txVersion, 3)
        XCTAssertEqual(tx.memo, Dao.memo(for: Dao.vote, callArgs: tx.callArgs))
    }

    func testStakingTransactions() throws {
        let key = try EgoKey(seed: [UInt8](repeating: 9, count: 32))
        let stake = try Staking.stake(key: key, amount: 5_000_000, lockDays: 90, nonce: 1, fee: 1_000)
        XCTAssertEqual(stake.to, Staking.address)
        XCTAssertEqual(stake.memo, "stake:90")
        XCTAssertEqual(stake.txType, "stake")
        XCTAssertThrowsError(try Staking.stake(key: key, amount: 5_000_000, lockDays: 0, nonce: 1, fee: 1_000))
        XCTAssertThrowsError(try Staking.stake(key: key, amount: 0, lockDays: 30, nonce: 1, fee: 1_000))
        let early = try Staking.unstake(key: key, staked: 5_000_000, early: true, nonce: 2, fee: 1_000)
        XCTAssertEqual(early.memo, "unstake:early")
        XCTAssertEqual(early.amount, 5_000_000)
        XCTAssertEqual(try Staking.unstake(key: key, staked: 5_000_000, early: false, nonce: 2, fee: 1_000).memo, "unstake")
    }

    private func proposal(endsAt: Int64, revealed: Bool, score: Double? = nil, status: String = "expired") throws -> Dao.Proposal {
        let json = """
        {"id":"\(id)","title":"T","description":"D","proposal_type":"feature","options":["Yes","No"],"creator":"egot1c",
         "created_at":0,"voting_ends_at":\(endsAt),"status":"\(status)","has_knowledge_test":true,"question_count":2,
         "stake_vote_count":3,"knowledge_vote_count":1,"questions":[{"id":"q0","question":"Q?","options":["a","b"]}],
         "my_stake_vote":null,"my_knowledge_vote":1,"my_test_score":\(score.map { "\($0)" } ?? "null"),
         "on_chain":true,"answers_revealed":\(revealed)}
        """
        return try JSONDecoder().decode(Dao.Proposal.self, from: Data(json.utf8))
    }

    func testRevealTiming() throws {
        let week = Dao.revealWindow
        let creator = Dao.Secret(id: id, salt: "s", answers: [1], isCreator: true)
        let voter = Dao.Secret(id: id, salt: "s", answers: [1], isCreator: false)

        XCTAssertFalse(Dao.revealDue(creator, proposal: try proposal(endsAt: 1_000, revealed: false, status: "active"), now: 999))
        XCTAssertTrue(Dao.revealDue(creator, proposal: try proposal(endsAt: 1_000, revealed: false), now: 1_000))
        XCTAssertFalse(Dao.revealDue(creator, proposal: try proposal(endsAt: 1_000, revealed: false), now: 1_000 + week))
        XCTAssertFalse(Dao.revealDue(creator, proposal: try proposal(endsAt: 1_000, revealed: true), now: 2_000))

        XCTAssertFalse(Dao.revealDue(voter, proposal: try proposal(endsAt: 1_000, revealed: false), now: 2_000))
        XCTAssertTrue(Dao.revealDue(voter, proposal: try proposal(endsAt: 1_000, revealed: true), now: 1_000 + week + 5))
        XCTAssertFalse(Dao.revealDue(voter, proposal: try proposal(endsAt: 1_000, revealed: true, score: 0.5), now: 2_000))
        XCTAssertFalse(Dao.revealDue(voter, proposal: try proposal(endsAt: 1_000, revealed: true, status: "withdrawn"), now: 2_000))

        XCTAssertTrue(Dao.revealFinished(voter, proposal: try proposal(endsAt: 1_000, revealed: true, score: 1), now: 2_000))
        XCTAssertTrue(Dao.revealFinished(voter, proposal: try proposal(endsAt: 1_000, revealed: true), now: 1_000 + 2 * week))
        XCTAssertFalse(Dao.revealFinished(voter, proposal: nil, now: 9_999_999))
    }

    func testStakingStatusDecodes() throws {
        let json = """
        {"address":"egot1x","staked":5000000,"started_at":100,"lock_days":90,"unlock_at":7776100,"locked":true,"apr":7.0,
         "accrued":1234,"early_fee":500000,"vote_locked_until":0,"can_unstake":true,"network_stake":20000000,
         "staking_address":"egot1staking000000000000000000000000000000000",
         "lock_options":[{"days":30,"apr":5.0},{"days":90,"apr":7.0}],"max_lock_days":1825}
        """
        let s = try JSONDecoder().decode(Staking.Status.self, from: Data(json.utf8))
        XCTAssertEqual(s.share, 0.25)
        XCTAssertEqual(s.lockOptions.map(\.days), [30, 90])
    }
}
