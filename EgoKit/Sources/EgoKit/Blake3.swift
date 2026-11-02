import Foundation

/// BLAKE3 in hash mode with a 32-byte output, following the reference implementation.
/// The node uses it to bind a transaction's body to its memo and to name waiting vault sends.
public enum Blake3 {
    static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]
    static let permutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
    static let chunkStart: UInt32 = 1
    static let chunkEnd: UInt32 = 2
    static let parent: UInt32 = 4
    static let root: UInt32 = 8
    static let blockLen = 64
    static let chunkLen = 1024

    public static func hash(_ input: [UInt8]) -> [UInt8] {
        var hasher = Hasher()
        hasher.update(input)
        return hasher.finalize()
    }

    public static func hex(_ input: [UInt8]) -> String {
        Hex.encode(hash(input))
    }

    public static func hex(_ text: String) -> String {
        hex(Array(text.utf8))
    }

    @inline(__always)
    static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    @inline(__always)
    static func g(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ mx: UInt32, _ my: UInt32) {
        s[a] = s[a] &+ s[b] &+ mx
        s[d] = rotr(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]
        s[b] = rotr(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b] &+ my
        s[d] = rotr(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]
        s[b] = rotr(s[b] ^ s[c], 7)
    }

    static func round(_ s: inout [UInt32], _ m: [UInt32]) {
        g(&s, 0, 4, 8, 12, m[0], m[1])
        g(&s, 1, 5, 9, 13, m[2], m[3])
        g(&s, 2, 6, 10, 14, m[4], m[5])
        g(&s, 3, 7, 11, 15, m[6], m[7])
        g(&s, 0, 5, 10, 15, m[8], m[9])
        g(&s, 1, 6, 11, 12, m[10], m[11])
        g(&s, 2, 7, 8, 13, m[12], m[13])
        g(&s, 3, 4, 9, 14, m[14], m[15])
    }

    static func compress(cv: [UInt32], block: [UInt32], counter: UInt64, blockLen: UInt32, flags: UInt32) -> [UInt32] {
        var s: [UInt32] = [
            cv[0], cv[1], cv[2], cv[3], cv[4], cv[5], cv[6], cv[7],
            iv[0], iv[1], iv[2], iv[3],
            UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32), blockLen, flags,
        ]
        var m = block
        for r in 0..<7 {
            round(&s, m)
            if r < 6 {
                m = permutation.map { m[$0] }
            }
        }
        for i in 0..<8 {
            s[i] ^= s[i + 8]
            s[i + 8] ^= cv[i]
        }
        return s
    }

    static func words(_ bytes: [UInt8]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let j = i * 4
            out[i] = UInt32(bytes[j]) | UInt32(bytes[j + 1]) << 8 | UInt32(bytes[j + 2]) << 16 | UInt32(bytes[j + 3]) << 24
        }
        return out
    }

    struct Output {
        let cv: [UInt32]
        let block: [UInt32]
        let counter: UInt64
        let blockLen: UInt32
        let flags: UInt32

        func chainingValue() -> [UInt32] {
            Array(compress(cv: cv, block: block, counter: counter, blockLen: blockLen, flags: flags).prefix(8))
        }

        func rootBytes() -> [UInt8] {
            let w = compress(cv: cv, block: block, counter: 0, blockLen: blockLen, flags: flags | root)
            var out = [UInt8]()
            out.reserveCapacity(32)
            for word in w.prefix(8) {
                out.append(UInt8(truncatingIfNeeded: word))
                out.append(UInt8(truncatingIfNeeded: word >> 8))
                out.append(UInt8(truncatingIfNeeded: word >> 16))
                out.append(UInt8(truncatingIfNeeded: word >> 24))
            }
            return out
        }
    }

    struct ChunkState {
        var cv: [UInt32]
        let counter: UInt64
        var block = [UInt8](repeating: 0, count: 64)
        var blockLen = 0
        var compressed = 0

        init(counter: UInt64) {
            cv = iv
            self.counter = counter
        }

        var length: Int { blockLen + compressed * blockLenConst }
        var blockLenConst: Int { 64 }
        var startFlag: UInt32 { compressed == 0 ? chunkStart : 0 }

        mutating func update(_ input: ArraySlice<UInt8>) {
            var rest = input
            while !rest.isEmpty {
                if blockLen == 64 {
                    cv = Array(compress(cv: cv, block: words(block), counter: counter, blockLen: 64, flags: startFlag).prefix(8))
                    compressed += 1
                    block = [UInt8](repeating: 0, count: 64)
                    blockLen = 0
                }
                let take = min(64 - blockLen, rest.count)
                for (i, b) in rest.prefix(take).enumerated() {
                    block[blockLen + i] = b
                }
                blockLen += take
                rest = rest.dropFirst(take)
            }
        }

        func output() -> Output {
            Output(cv: cv, block: words(block), counter: counter, blockLen: UInt32(blockLen), flags: startFlag | chunkEnd)
        }
    }

    struct Hasher {
        var chunk = ChunkState(counter: 0)
        var stack: [[UInt32]] = []

        static func parentOutput(_ left: [UInt32], _ right: [UInt32]) -> Output {
            Output(cv: iv, block: left + right, counter: 0, blockLen: 64, flags: parent)
        }

        mutating func push(_ cv: [UInt32], totalChunks: UInt64) {
            var newCV = cv
            var total = totalChunks
            while total & 1 == 0 {
                newCV = Hasher.parentOutput(stack.removeLast(), newCV).chainingValue()
                total >>= 1
            }
            stack.append(newCV)
        }

        mutating func update(_ input: [UInt8]) {
            var rest = input[...]
            while !rest.isEmpty {
                if chunk.length == chunkLen {
                    let cv = chunk.output().chainingValue()
                    let total = chunk.counter + 1
                    push(cv, totalChunks: total)
                    chunk = ChunkState(counter: total)
                }
                let take = min(chunkLen - chunk.length, rest.count)
                chunk.update(rest.prefix(take))
                rest = rest.dropFirst(take)
            }
        }

        func finalize() -> [UInt8] {
            var output = chunk.output()
            var remaining = stack.count
            while remaining > 0 {
                remaining -= 1
                output = Hasher.parentOutput(stack[remaining], output.chainingValue())
            }
            return output.rootBytes()
        }
    }
}
