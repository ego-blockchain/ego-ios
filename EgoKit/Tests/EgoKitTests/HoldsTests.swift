import XCTest
@testable import EgoKit

final class HoldsTests: XCTestCase {
    /// Pinned in Ego Desktop's phone_dao tests too.
    func testVoteMemoMatchesTheNode() throws {
        let body = try Dao.body(Holds.VoteBody(id: "hold0123456789abcdef", phase: "confirm", yes: true))
        XCTAssertEqual(body, #"{"id":"hold0123456789abcdef","phase":"confirm","yes":true}"#)
        XCTAssertEqual(Holds.memo(for: Holds.vote, callArgs: body), "hold:vote:b1345742d18521913f54d3a1bc0302c71d10471f8bbcaa67b30a03b4abfca2e0")
        XCTAssertNil(Holds.memo(for: "dao_vote", callArgs: body))
    }

    func testAHoldDecodesAndKnowsWhatYouCanDo() throws {
        let json = """
        {"id":"hold1","requester":"egot1r","victim":"egot1v","case":"Phished","bond":100000000,"theft":["0xaa"],"hops":[],
         "created":10,"phase":"voting","amounts":[["egot1thief",5000000]],"held_at":20,"vote_ends":300,"return_opened":0,
         "return_ends":0,"appeals":[],"confirm":{"stake_yes":1,"stake_no":0,"stake_voters":1,"node_yes":0,"node_no":0,"node_voters":0},
         "ret":{"stake_yes":0,"stake_no":0,"stake_voters":0,"node_yes":0,"node_no":0,"node_voters":0},
         "my_stake_vote":null,"my_node_vote":null,"my_return_stake_vote":null,"my_return_node_vote":null,
         "stake_total":9,"node_total":0,"committee":64,"paid":false}
        """
        let h = try JSONDecoder().decode(Holds.Hold.self, from: Data(json.utf8))
        XCTAssertEqual(h.held, [Holds.Held(address: "egot1thief", amount: 5_000_000)])
        XCTAssertEqual(h.openVote, "confirm")
        XCTAssertTrue(h.canAppeal("egot1thief"))
        XCTAssertFalse(h.canAppeal("egot1v"))
        XCTAssertFalse(h.canOpenReturn("egot1v"))
    }
}
