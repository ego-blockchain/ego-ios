import XCTest
@testable import EgoKit

final class StorageRecordTests: XCTestCase {
    private let first = Data((0 ..< 2500).map { UInt8(($0 * 7 + 3) % 256) })
    private let second = Data((0 ..< 2500).map { UInt8(($0 * 13 + 1) % 256) })

    func testTheRecordMatchesWhatTheNodeWorksOut() throws {
        let r = StorageRecord.record(cid: "egomfd1test", blocks: [first, second])
        XCTAssertEqual(r.commD, "99ab8af962f138bf5869373cff059a8683962ca2ed3b9b81876062c04ab31281")
        XCTAssertEqual(r.nRealLeaves, 5)
        XCTAssertEqual(r.nPaddedLeaves, 8)
        XCTAssertEqual(r.bytes, 5000)
        let body = try StorageRecord.body(r)
        XCTAssertEqual(body, #"{"bytes":5000,"cid":"egomfd1test","comm_d":"99ab8af962f138bf5869373cff059a8683962ca2ed3b9b81876062c04ab31281","n_padded_leaves":8,"n_real_leaves":5}"#)
        XCTAssertEqual(StorageRecord.memo(body: body, delete: false), "storage_file:0c29394d1bb6f1feb85d6194f9de3fc73edae25cf657d1cbe348afd6c97a5ce4")
    }

    func testPiecesRunAcrossBlockBoundaries() {
        let whole = first + second
        let split = StorageRecord.record(cid: "x", blocks: [whole.prefix(1), whole.dropFirst(1).prefix(2047), whole.dropFirst(2048)])
        XCTAssertEqual(split, StorageRecord.record(cid: "x", blocks: [whole]))
    }

    func testOnePieceIsItsOwnRoot() {
        let r = StorageRecord.record(cid: "x", blocks: [Data(0 ..< 10)])
        XCTAssertEqual(r.commD, "87fcf07cac5be3c91735b34e535c67286e4e7a63bf152d95f2cf4cd1a244758b")
        XCTAssertEqual(r.nRealLeaves, 1)
        XCTAssertEqual(r.nPaddedLeaves, 1)
    }

    func testARemovalNamesOnlyTheFile() throws {
        let body = try StorageRecord.body(.removal(of: "egomfd1gone"))
        XCTAssertEqual(body, #"{"bytes":0,"cid":"egomfd1gone","comm_d":"","n_padded_leaves":0,"n_real_leaves":0}"#)
        XCTAssertTrue(StorageRecord.memo(body: body, delete: true).hasPrefix("storage_file:delete:"))
    }
}
