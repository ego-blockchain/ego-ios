import XCTest
@testable import EgoKit

final class TotpTests: XCTestCase {
    private let secret = Data("12345678901234567890".utf8)

    func testCodesMatchTheRfc6238Vectors() {
        let vectors: [(Int64, UInt32)] = [(59, 287_082), (1_111_111_109, 81_804), (1_111_111_111, 50_471), (1_234_567_890, 5_924), (2_000_000_000, 279_037)]
        for (time, expected) in vectors {
            XCTAssertEqual(Totp.code(secret: secret, step: time / Totp.period), expected, "time \(time)")
        }
    }

    func testACodeCountsForOneStepEitherSideOnly() {
        let now: Int64 = 1_234_567_890
        let code = { (t: Int64) in String(format: "%06u", Totp.code(secret: self.secret, step: t / Totp.period)) }
        XCTAssertEqual(Totp.matchingStep(secret: secret, entered: code(now), now: now), now / Totp.period)
        XCTAssertNotNil(Totp.matchingStep(secret: secret, entered: code(now - Totp.period), now: now))
        XCTAssertNotNil(Totp.matchingStep(secret: secret, entered: code(now + Totp.period), now: now))
        XCTAssertNil(Totp.matchingStep(secret: secret, entered: code(now - 3 * Totp.period), now: now))
        XCTAssertNil(Totp.matchingStep(secret: secret, entered: "12345", now: now))
        XCTAssertNil(Totp.matchingStep(secret: secret, entered: "12a456", now: now))
    }

    func testBase32MatchesTheRfc4648Vectors() {
        XCTAssertEqual(Totp.base32(Data()), "")
        XCTAssertEqual(Totp.base32(Data("f".utf8)), "MY")
        XCTAssertEqual(Totp.base32(Data("fo".utf8)), "MZXQ")
        XCTAssertEqual(Totp.base32(Data("foobar".utf8)), "MZXW6YTBOI")
        XCTAssertEqual(Totp.base32(secret), "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    }

    func testTheSetupLinkIsWhatAuthenticatorAppsRead() {
        let uri = Totp.setupURI(secret: secret, address: "egot1ypxxgvy0y5g8gynm3y2tkegzggs64rcts5dq7sl8")
        XCTAssertTrue(uri.hasPrefix("otpauth://totp/Ego%20Wallet:egot1ypxxg...7sl8?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"), uri)
        XCTAssertTrue(uri.contains("digits=6") && uri.contains("period=30") && uri.contains("issuer=Ego%20Wallet"))
        XCTAssertEqual(Totp.newSecret().count, Totp.secretBytes)
        XCTAssertNotEqual(Totp.newSecret(), Totp.newSecret())
    }
}
