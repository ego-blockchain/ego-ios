#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import EgoKit
import Foundation
import XCTest

final class MessengerTests: XCTestCase {
    func testBlake3DeriveKeyMatchesTheReferenceVector() {
        XCTAssertEqual(Hex.encode(Blake3.deriveKey(context: "BLAKE3 2019-12-27 16:29:52 test vectors context", material: [])),
                       "2cc39783c223154fea8dfb7c1b1660f2ac2dcbd1c1de8277b0b0dd39b7e50d7d")
        XCTAssertEqual(Blake3.hex(""), "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
    }

    func testRatchetKeysMatchTheDesktop() {
        let shared = [UInt8](repeating: 5, count: 32)
        XCTAssertEqual(Messenger.messageKey(shared: shared, sending: true, me: "egot1a", peer: "egot1b", seq: 1).map(Hex.encode),
                       "3997b123a79775169fbff52b178a968fa3266e6b50ea8eb9f496b6dca934c0af")
        XCTAssertEqual(Messenger.messageKey(shared: shared, sending: true, me: "egot1a", peer: "egot1b", seq: 3).map(Hex.encode),
                       "2a2bf0f76ef65f416186db15771d4a26f76116afe44fafb6c9f28f18a8c8eaae")
        XCTAssertEqual(Messenger.messageKey(shared: shared, sending: false, me: "egot1a", peer: "egot1b", seq: 1).map(Hex.encode),
                       "1dcb7320c0899a34810b8db102e42f2ba7a961ae85825e5523c41f354fcfcf14")
        let cache = RatchetCache()
        XCTAssertEqual(cache.key(shared: shared, sending: true, me: "egot1a", peer: "egot1b", seq: 1).map(Hex.encode),
                       "3997b123a79775169fbff52b178a968fa3266e6b50ea8eb9f496b6dca934c0af")
        XCTAssertEqual(cache.key(shared: shared, sending: true, me: "egot1a", peer: "egot1b", seq: 3).map(Hex.encode),
                       "2a2bf0f76ef65f416186db15771d4a26f76116afe44fafb6c9f28f18a8c8eaae")
    }

    func testThePhoneReadsAMessageTheDesktopSent() {
        let text = "egomsg1:egot1a:egot1b:1800000000:text:010101010101010101010101:e57ad9294306f690ae510b1f9cb9ccf65bf048b3686d70781e580f0ec6aae9f8d5e0"
        let bundle = Messenger.Bundle(parsing: text)!
        XCTAssertEqual(bundle.id, "1800000000-01010101")
        let shared = String(repeating: "05", count: 32)
        XCTAssertEqual(Messenger.decrypt(bundle, seq: 3, me: "egot1b", sharedKeyHex: shared), "hello from desktop")
        XCTAssertEqual(Messenger.decrypt(bundle, seq: 3, me: "egot1a", sharedKeyHex: shared), "hello from desktop", "the phone of the wallet that sent it reads it too")
        XCTAssertNil(Messenger.decrypt(bundle, seq: 2, me: "egot1b", sharedKeyHex: shared))
    }

    func testThePhoneOpensAnEnvelopeTheDesktopSealed() {
        let sealed = Messenger.Sealed(
            to: "egot1recipient",
            ephPub: "13be4feaeaf204c7fd3358fc9c00721881d174278128227ec674f37f7fe97b6d",
            nonce: "090909090909090909090909",
            ct: "f9f981b3b3b46c61a6ff4819e0ed94e710102fef97b2927f9ac038e331df15f607c45b1e381bc910c41e0ee5505afc196e3b68ce9efca08d44bc092d7b7101d843cadab02073f734811f382a2cc820eac15bd2b1bca7944a23422c9be5",
            id: "8473410a3926753a6e2b9414840f1897")
        let inner = Messenger.open(sealed, seed: [UInt8](repeating: 42, count: 32))
        XCTAssertEqual(inner?.type, "chat_message")
        XCTAssertEqual(inner?.bundle, "egomsg1:egot1a:egot1b:1:text:00:ff")
        XCTAssertEqual(inner?.seq, 3)
        XCTAssertNil(Messenger.open(sealed, seed: [UInt8](repeating: 9, count: 32)))
    }

    func testTheEdwardsKeyConvertsToTheSameAgreementKeyTheDesktopUses() throws {
        for fill in [UInt8(1), 7, 42, 200, 255] {
            let seed = [UInt8](repeating: fill, count: 32)
            let ed = Array(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed)).publicKey.rawRepresentation)
            let x = Array(try Messenger.agreementKey(seed: seed).publicKey.rawRepresentation)
            XCTAssertEqual(Field25519.montgomery(fromEdwards: ed), x, "seed filled with \(fill)")
        }
    }

    func testSomethingSealedOnThePhoneOpensForItsAddressee() throws {
        let seed = [UInt8](repeating: 77, count: 32)
        let ed = Array(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed)).publicKey.rawRepresentation)
        let plain = try Messenger.Outgoing.data(Messenger.Outgoing.receipt(read: true, from: "egot1me", to: "egot1you", ids: ["1-ab"]))
        let sealed = try Messenger.seal(plain, to: "egot1you", ed25519: ed)
        XCTAssertEqual(sealed.id, Hex.encode(Array(Blake3.hash(Array(sealed.ct.utf8)).prefix(16))))
        let inner = Messenger.open(sealed, seed: seed)
        XCTAssertEqual(inner?.type, "read_receipt")
        XCTAssertEqual(inner?.messageIds, ["1-ab"])
        XCTAssertNil(Messenger.open(sealed, seed: [UInt8](repeating: 78, count: 32)))
    }

    func testOnlyContactRequestsToOthersAskForAnAlert() throws {
        let request = Messenger.Outgoing.contactRequest(from: "egot1me", name: "Me", ed25519Hex: "00", sharedKeyHex: "11", token: "")
        XCTAssertEqual(Messenger.alert(for: request, to: "egot1you"), Messenger.alertRequest)
        XCTAssertEqual(Messenger.alert(for: request, to: "egot1me"), "")
        XCTAssertEqual(Messenger.alert(for: Messenger.Outgoing.receipt(read: true, from: "egot1me", to: "egot1you", ids: ["x"]), to: "egot1you"), "")
        XCTAssertEqual(Messenger.alert(for: Messenger.Outgoing.profile(from: "egot1me", avatar: "", name: "Me"), to: "egot1you"), "")

        let seed = [UInt8](repeating: 77, count: 32)
        let ed = Array(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed)).publicKey.rawRepresentation)
        let quiet = try Messenger.seal(Data("{}".utf8), to: "egot1you", ed25519: ed)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(quiet), as: UTF8.self).contains("alert"))
        let loud = try Messenger.seal(Data("{}".utf8), to: "egot1you", ed25519: ed, alert: Messenger.alertRequest)
        let json = String(decoding: try JSONEncoder().encode(loud), as: UTF8.self)
        XCTAssertTrue(json.contains("\"alert\":\"request\""))
        XCTAssertEqual(try JSONDecoder().decode(Messenger.Sealed.self, from: Data(json.utf8)), loud)
        XCTAssertEqual(try JSONDecoder().decode(Messenger.Sealed.self, from: try JSONEncoder().encode(quiet)).alert, "")
    }

    func testAnAlertKeyGrantMatchesTheDesktopAndVerifies() throws {
        XCTAssertEqual(Messenger.readerBytes(owner: "egot1a", reader: "ff", until: 9), Array("ego/mail-reader/v1\negot1a\nff\n9".utf8))
        XCTAssertEqual(Messenger.peekBytes(owner: "egot1a", reader: "ff", ts: 5, since: 7), Array("ego/mail-peek/v1\negot1a\nff\n5\n7".utf8))
        let key = try EgoKey(seed: [UInt8](repeating: 5, count: 32))
        let reader = Curve25519.Signing.PrivateKey()
        let now: Int64 = 1_000_000
        let grant = try Messenger.ReaderGrant.make(reader: Array(reader.publicKey.rawRepresentation), with: key, now: now)
        XCTAssertEqual(grant.owner, key.address)
        XCTAssertEqual(grant.until, now + 90 * 86_400)
        let owner = try Curve25519.Signing.PublicKey(rawRepresentation: Data(key.publicKey))
        let message = Data(Messenger.readerBytes(owner: grant.owner, reader: grant.reader, until: grant.until))
        XCTAssertTrue(owner.isValidSignature(Data(Hex.decode(grant.grant) ?? []), for: message))
        XCTAssertFalse(grant.needsRenewal(now: now + 29 * 86_400))
        XCTAssertTrue(grant.needsRenewal(now: now + 31 * 86_400))
        let saved = try JSONDecoder().decode(Messenger.ReaderGrant.self, from: try JSONEncoder().encode(grant))
        XCTAssertEqual(saved, grant)
    }

    func testContactCardsRoundTripAndMatchTheDesktopFormat() {
        let ed = [UInt8](repeating: 3, count: 32)
        let card = Messenger.ContactCard(address: "egot1abc", ed25519: ed, name: "Ana", endpoint: "", token: "ff00")
        XCTAssertEqual(card.text, "egocontact1:egot1abc:\(Data(ed).base64EncodedString()):QW5h::ff00")
        XCTAssertEqual(Messenger.ContactCard(parsing: card.text), card)
        XCTAssertNil(Messenger.ContactCard(parsing: "egocontact1:egot1abc:short:QW5h::ff00"))
        XCTAssertEqual(Messenger.publicKey(ed25519: Hex.encode(ed)), ed)
        XCTAssertEqual(Messenger.publicKey(ed25519: Data(ed).base64EncodedString()), ed)
    }

    func testHistoryFromTheDesktopDecodes() throws {
        let json = #"{"type":"history","messages":[{"id":"1-aa","from":"egot1a","to":"egot1b","ts":1,"type":"text","content":"hi","reply_to":null,"reactions":[{"emoji":"heart","from":"egot1b"}],"edited_at":null,"delivered":true,"read":false}],"profiles":[{"address":"egot1b","name":"B","avatar":"data:image/png;base64,AA"}]}"#
        let inner = try JSONDecoder().decode(Messenger.Inner.self, from: Data(json.utf8))
        XCTAssertEqual(inner.messages?.first?.reactions.first?.emoji, "heart")
        XCTAssertEqual(inner.messages?.first?.delivered, true)
        XCTAssertEqual(inner.profiles?.first?.avatar, "data:image/png;base64,AA")
        let request = try JSONDecoder().decode(Messenger.Inner.self, from: Messenger.Outgoing.data(
            Messenger.Outgoing.contactRequest(from: "egot1a", name: "A", ed25519Hex: "00", sharedKeyHex: "11", token: "")))
        XCTAssertEqual(request.type, "contact_request")
        XCTAssertEqual(request.fromSharedKey, "11")
        XCTAssertNil(request.bundleToken)
    }
}
