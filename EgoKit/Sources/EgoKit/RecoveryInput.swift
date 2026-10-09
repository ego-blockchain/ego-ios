/// What someone types to restore a wallet: the 24 recovery words, or the raw
/// seed as Ego Desktop shows it under "Raw Seed (hex)", 64 hex characters in
/// groups of eight. Both give the same 32-byte seed, so the same address.
public enum RecoveryInput {
    public enum Problem: Error, Equatable {
        case unknownWord(String)
        case invalidPhrase
        case invalidSeed
    }

    public static let seedHexLength = 64

    public static func seed(from text: String) -> Result<[UInt8], Problem> {
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let hex = seedHex(parts) {
            guard hex.count == seedHexLength, let seed = Hex.decode(hex) else { return .failure(.invalidSeed) }
            return .success(seed)
        }
        let words = parts.map { $0.lowercased() }
        if let unknown = words.first(where: { !Mnemonic.isWord($0) }) {
            return .failure(.unknownWord(unknown))
        }
        guard let seed = Mnemonic.seed(from: words) else { return .failure(.invalidPhrase) }
        return .success(seed)
    }

    /// Whether there's enough to try: 24 words, or 64 hex characters.
    public static func looksComplete(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let hex = seedHex(parts) { return hex.count == seedHexLength }
        return parts.count == Mnemonic.wordCount
    }

    /// The parts joined into one hex string, if that's what they are. Recovery
    /// words are letters only and always include some outside a–f.
    private static func seedHex(_ parts: [String]) -> String? {
        var joined = parts.joined()
        if joined.hasPrefix("0x") || joined.hasPrefix("0X") { joined.removeFirst(2) }
        guard !joined.isEmpty, joined.allSatisfy(\.isHexDigit), joined.contains(where: \.isNumber) || joined.count == seedHexLength
        else { return nil }
        return joined
    }
}
