import XCTest
@testable import EgoKit

final class RecoveryInputTests: XCTestCase {
    let seed: [UInt8] = (0..<32).map { UInt8($0 * 7 + 3) }

    /// Ego Desktop shows the raw seed as eight groups of eight hex characters.
    var desktopHex: String {
        let hex = Hex.encode(seed)
        return stride(from: 0, to: 64, by: 8).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 8)])
        }.joined(separator: " ")
    }

    func testTheRawSeedAsEgoDesktopShowsItRestoresTheSameSeed() {
        XCTAssertEqual(try RecoveryInput.seed(from: desktopHex).get(), seed)
        XCTAssertEqual(try RecoveryInput.seed(from: Hex.encode(seed).uppercased()).get(), seed)
        XCTAssertEqual(try RecoveryInput.seed(from: "0x" + Hex.encode(seed)).get(), seed)
        XCTAssertEqual(try RecoveryInput.seed(from: "\n " + desktopHex.replacingOccurrences(of: " ", with: "\n") + " \n").get(), seed)
        XCTAssertTrue(RecoveryInput.looksComplete(desktopHex))
    }

    func testTheRawSeedAndThePhraseGiveTheSameWallet() throws {
        let phrase = Mnemonic.words(for: seed).joined(separator: " ")
        XCTAssertEqual(try RecoveryInput.seed(from: phrase).get(), try RecoveryInput.seed(from: desktopHex).get())
        XCTAssertTrue(RecoveryInput.looksComplete(phrase))
    }

    func testAShortOrBrokenSeedIsRefused() {
        let hex = Hex.encode(seed)
        XCTAssertEqual(RecoveryInput.seed(from: String(hex.dropLast(2))), .failure(.invalidSeed))
        XCTAssertEqual(RecoveryInput.seed(from: hex + "00"), .failure(.invalidSeed))
        XCTAssertFalse(RecoveryInput.looksComplete(String(hex.dropLast(1))))
    }

    func testWordsAreStillCheckedAsWords() {
        var words = Mnemonic.words(for: seed)
        XCTAssertFalse(RecoveryInput.looksComplete(words.prefix(3).joined(separator: " ")))
        words[5] = "notaword"
        XCTAssertEqual(RecoveryInput.seed(from: words.joined(separator: " ")), .failure(.unknownWord("notaword")))
    }
}
