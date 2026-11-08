import XCTest
@testable import EgoKit

final class AccountRecordTests: XCTestCase {
    private let fixture = #"{"owner":"egot1yq4xhaep9ne54m33sc9dj0lh2k7mam5zmc6s5max","pubkey":"fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618","slot":"desktop","ver":1800000000000,"data":"jiuR5E0D659H1HmDJTI1PIRUj6EIVsFLkHvCqijT8PeKR4Kcdpzou1Q2uX/LIF8MlHxbQAtAwQgHCwl9MZt2qQe3a1DK9uq2LuLthTFzjGjTDcaQjUUQy0fe9WjG7btBiOUJk3hRkfzIPDRiUJsvGFv/GaRKxuEsO0NAOc1Boh5zzL+yCTqP06jXVWbFbW/GAQK007OJn/yUAVCePGU1gqSoiq3kzgbKhWF8yyRAqbhsqWh1rnqFhSDGLCIrNzNnogA74itAoLiDFHagOYNvpA3mQlr000FEIOFFKCtPqvSGVUXC5TlHzAVf1JlKi0efujHd8y0si7E8hykAGxuM+mzMSQcAAwUA4+GMDm5QMjVlULxExoSv/g/xK8ShP3NCIS0YFt6DOJEYOUffEzqiH5uXnLKyZykU+mq1xH/SDXkPpSZYxEEEcfvYZ8g6mo2KqhwFi5DxXKIj7mn/YqqGKbm3hiL3MRusE4DGjJBXSqiP7gXAheTu72ekLfddUVWlOW09ltoBUMuTb4zDMiqD+l0x5usKBlDLQUvvEf7zioX5v14ts4fcajNQoUkthQsDB8FnY9QX7czpfgrqwV3fC42W5JOH0zpNiIn9o/QQa+7ShAx18KvJVX5wJfnZntJ4laABMlVvUOOAO3X9HCWtAmsQRWkxriWWCiPdF4rdgnkyDm7xHbXm4rpQ2Z8d6MJZl7x/as+gs7DGSTIJo/m43redFAS+KMVVFnjyNDKx49XuB7fLucVxb0AbPffbVXWykA1JplDrzHVxx0H6ljULe3Y5p+4qZELcdSpu5nkvnwTmlidpxg==","sig":"d0fd8a5020ad6cb4705a9e592a4935064736f976063a72f2f15f664ecf2fa57624bd4ba2722f3426720ae00042ab02642f539e7d3114567b7a897bde53c6910c"}"#

    private func key(_ byte: UInt8) -> EgoKey {
        try! EgoKey(seed: [UInt8](repeating: byte, count: 32))
    }

    func testTheDesktopsRecordOpensOnThePhone() throws {
        let envelope = try JSONDecoder().decode(AccountRecord.Envelope.self, from: Data(fixture.utf8))
        let me = key(9)
        XCTAssertEqual(envelope.owner, me.address, "the desktop and the phone name the same wallet")
        XCTAssertTrue(AccountRecord.isGenuine(envelope, owner: me.address, slot: AccountRecord.desktop))
        let content = try AccountRecord.open(envelope, with: me)
        XCTAssertEqual(content.bundle, "egocontact1:egot1x:a:b:c:d")
        XCTAssertEqual(content.contacts.first?.sharedKeyHex, String(repeating: "00", count: 32))
        XCTAssertEqual(content.files.first?.name, "cat.jpg")
        XCTAssertEqual(content.files.first?.shareLink(from: me.address), "egoshare1:egomfd1aa:\(String(repeating: "11", count: 44)):Y2F0LmpwZw==:\(me.address)")
        XCTAssertEqual(content.payments.first?.blockHeight, 85459)
        XCTAssertThrowsError(try AccountRecord.open(envelope, with: key(8)), "another wallet can't read it")
        XCTAssertFalse(AccountRecord.isGenuine(envelope, owner: me.address, slot: AccountRecord.phone), "the slot is signed")
    }

    func testThePhoneAndTheDesktopAgreeOnKeysPlacesAndSignatures() {
        let seed = (0..<32).map { UInt8($0) }
        XCTAssertEqual(AccountRecord.recordKey(seed: seed).withUnsafeBytes { Hex.encode(Array($0)) },
                       "be1be4f26b8d319885ee05cca56d4e0935d07bde67ddc25d9fafc0e7dd15a769")
        let nodes = (0..<50).map { "egot1node\($0)" }
        XCTAssertEqual(AccountRecord.places(owner: "egot1owner", nodes: nodes), ["egot1node31", "egot1node48", "egot1node10", "egot1node28"])
        XCTAssertEqual(String(decoding: AccountRecord.deliverBytes(owner: "egot1a", to: "egot1b", ts: 5, bundle: "egomsg1:x"), as: UTF8.self),
                       "ego/messenger-deliver/v1\negot1a\negot1b\n5\ndf99cc046926a28f6cfb7d7925b2e8c755502c2dfc9267184a132db39e10c413")
    }

    func testWhatThePhoneWritesItCanReadBack() throws {
        let me = key(4)
        var content = AccountRecord.Content()
        content.sent = [AccountRecord.Sent(id: "1-abcd", to: "egot1you", content: "egoshare1:x", messageType: "file_bundle", ts: 1)]
        let envelope = try AccountRecord.seal(content, with: me, slot: AccountRecord.phone, ver: 42)
        XCTAssertTrue(AccountRecord.isGenuine(envelope, owner: me.address, slot: AccountRecord.phone))
        XCTAssertEqual(try AccountRecord.open(envelope, with: me), content)
        let older = try AccountRecord.seal(content, with: me, slot: AccountRecord.phone, ver: 41)
        XCTAssertEqual(AccountRecord.newest([older, envelope], owner: me.address, slot: AccountRecord.phone)?.ver, 42)
    }

    func testAMessageFromThePhoneIsShapedLikeOneFromTheDesktop() throws {
        let me = key(4)
        let contact = AccountRecord.Contact(address: "egot1you", name: "You", ed25519: "k", sharedKeyHex: String(repeating: "07", count: 32))
        let message = try AccountRecord.chatMessage(from: me.address, to: contact.address, ts: 100, type: "file_bundle", text: "egoshare1:x", sharedKeyHex: contact.sharedKeyHex)
        let parts = message.bundle.split(separator: ":", maxSplits: 6).map(String.init)
        XCTAssertEqual(Array(parts.prefix(5)), ["egomsg1", me.address, "egot1you", "100", "file_bundle"])
        XCTAssertEqual(parts[5].count, 24, "a 12-byte nonce")
        XCTAssertEqual(parts[6].count, ("egoshare1:x".utf8.count + 16) * 2, "ciphertext followed by its tag")
        XCTAssertEqual(message.id, "100-\(parts[5].prefix(8))")
        XCTAssertThrowsError(try AccountRecord.chatMessage(from: me.address, to: "x", ts: 1, type: "text", text: "hi", sharedKeyHex: "00"))
        let delivery = try AccountRecord.delivery(of: message.bundle, to: contact, ts: 100, with: me)
        XCTAssertTrue(EgoKey.verify(signature: Hex.decode(delivery.sig)!, message: AccountRecord.deliverBytes(owner: me.address, to: "egot1you", ts: 100, bundle: message.bundle), publicKey: me.publicKey))
    }
}
