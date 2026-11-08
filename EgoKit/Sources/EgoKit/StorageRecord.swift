import Foundation

public enum StorageRecord {
    public static let pieceSize = 1024
    public static let txType = "storage_file"

    public struct Record: Codable, Equatable, Sendable {
        public let cid: String
        public let commD: String
        public let nRealLeaves: UInt64
        public let nPaddedLeaves: UInt64
        public let bytes: UInt64

        enum CodingKeys: String, CodingKey {
            case cid, bytes
            case commD = "comm_d"
            case nRealLeaves = "n_real_leaves"
            case nPaddedLeaves = "n_padded_leaves"
        }

        public init(cid: String, commD: String, nRealLeaves: UInt64, nPaddedLeaves: UInt64, bytes: UInt64) {
            self.cid = cid
            self.commD = commD
            self.nRealLeaves = nRealLeaves
            self.nPaddedLeaves = nPaddedLeaves
            self.bytes = bytes
        }

        public static func removal(of cid: String) -> Record {
            Record(cid: cid, commD: "", nRealLeaves: 0, nPaddedLeaves: 0, bytes: 0)
        }
    }

    public static func record(cid: String, blocks next: () throws -> Data?) rethrows -> Record {
        var leaves: [UInt8] = []
        var piece: [UInt8] = []
        piece.reserveCapacity(pieceSize)
        var total: UInt64 = 0
        while let block = try next() {
            total += UInt64(block.count)
            var i = block.startIndex
            while i < block.endIndex {
                let take = min(pieceSize - piece.count, block.endIndex - i)
                piece.append(contentsOf: block[i ..< i + take])
                i += take
                if piece.count == pieceSize {
                    leaves.append(contentsOf: Blake3.hash(piece))
                    piece.removeAll(keepingCapacity: true)
                }
            }
        }
        if !piece.isEmpty {
            leaves.append(contentsOf: Blake3.hash(piece))
        }
        let tree = root(leaves: leaves)
        return Record(cid: cid, commD: Hex.encode(tree.root), nRealLeaves: UInt64(tree.real), nPaddedLeaves: UInt64(tree.padded), bytes: total)
    }

    public static func record(cid: String, blocks: [Data]) -> Record {
        var it = blocks.makeIterator()
        return record(cid: cid) { it.next() }
    }

    static func root(leaves: [UInt8]) -> (root: [UInt8], real: Int, padded: Int) {
        let real = max(leaves.count / 32, 1)
        var padded = 1
        while padded < real { padded <<= 1 }
        var nodes = [UInt8](repeating: 0, count: 2 * padded * 32)
        nodes.replaceSubrange(padded * 32 ..< padded * 32 + leaves.count, with: leaves)
        var i = padded - 1
        while i >= 1 {
            let pair = Array(nodes[(2 * i) * 32 ..< (2 * i + 2) * 32])
            nodes.replaceSubrange(i * 32 ..< i * 32 + 32, with: Blake3.hash(pair))
            i -= 1
        }
        return (Array(nodes[32 ..< 64]), real, padded)
    }

    public static func body(_ record: Record) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    public static func memo(body: String, delete: Bool) -> String {
        (delete ? "storage_file:delete:" : "storage_file:") + Blake3.hex(body)
    }
}

public extension Transactions {
    static func storageFile(
        key: EgoKey, record: StorageRecord.Record, delete: Bool = false,
        nonce: UInt64, fee: UInt64, timestamp: Int64 = Int64(Date().timeIntervalSince1970), version: Int = 3
    ) throws -> SignedTransaction {
        let body = try StorageRecord.body(record)
        var tx = try sign(key: key, to: key.address, amount: 0, nonce: nonce, fee: fee,
                          memo: StorageRecord.memo(body: body, delete: delete),
                          txType: StorageRecord.txType, timestamp: timestamp, version: version)
        tx.callArgs = body
        return tx
    }
}

public extension GatewayClient {
    struct RecordStatus: Decodable, Sendable {
        public let recorded: Bool
        public let owner: String?
    }

    func storageRecorded(cid: String) async throws -> RecordStatus {
        try await call("storage.recorded", ["cid": cid])
    }

    func storageCommitment(cid: String) async throws -> StorageRecord.Record {
        try await call("storage.commitment", ["cid": cid])
    }
}
