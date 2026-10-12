import Foundation

public enum ChatRules {
    public static let maxBodyCharacters = 4_000
    public static let maxNameCharacters = 24
    public static let maxLines = 80
    public static let changeWindow: Int64 = 3_600

    public static func cleanBody(_ raw: String) -> String? {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
              body.unicodeScalars.count <= maxBodyCharacters,
              !body.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" }),
              body.split(separator: "\n", omittingEmptySubsequences: false).count <= maxLines
        else { return nil }
        return body
    }

    public static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.unicodeScalars.count <= maxNameCharacters,
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return name
    }

    /// A removal that never ends: someone removed a second time.
    public static func isForGood(_ until: Int64?) -> Bool { (until ?? 0) > 32_503_680_000 }

    public static func canChange(postTimestamp: Int64, now: Int64) -> Bool {
        now >= postTimestamp && now - postTimestamp < changeWindow
    }
}

public struct ChatPost: Codable, Equatable {
    public let from: String
    public let name: String
    public let body: String
    public let ts: Int64
    public var pubkey: String
    public var sig: String

    public var signingBytes: [UInt8] {
        Array("ego/dao-chat/post/v1\n\(from)\n\(ts)\n\(name)\n\(body)".utf8)
    }

    public var id: String {
        String(Hex.encode(Blake2s.hash(signingBytes)).prefix(32))
    }
}

public struct ChatVote: Codable, Equatable {
    public let voter: String
    public let target: String
    public let ts: Int64
    public var pubkey: String
    public var sig: String

    public var signingBytes: [UInt8] {
        Array("ego/dao-chat/vote/v1\n\(voter)\n\(target)\n\(ts)".utf8)
    }
}

public struct ChatName: Codable, Equatable {
    public let from: String
    public let name: String
    public let ts: Int64
    public var pubkey: String
    public var sig: String

    public var signingBytes: [UInt8] {
        Array("ego/dao-chat/name/v1\n\(from)\n\(ts)\n\(name)".utf8)
    }
}

public struct ChatEdit: Codable, Equatable {
    public let from: String
    public let postId: String
    public let postTs: Int64
    public let body: String
    public let ts: Int64
    public var pubkey: String
    public var sig: String

    enum CodingKeys: String, CodingKey {
        case from, body, ts, pubkey, sig
        case postId = "post_id"
        case postTs = "post_ts"
    }

    public var signingBytes: [UInt8] {
        Array("ego/dao-chat/edit/v1\n\(from)\n\(postId)\n\(postTs)\n\(ts)\n\(body)".utf8)
    }
}

public struct ChatDelete: Codable, Equatable {
    public let from: String
    public let postId: String
    public let postTs: Int64
    public let ts: Int64
    public var pubkey: String
    public var sig: String

    enum CodingKeys: String, CodingKey {
        case from, ts, pubkey, sig
        case postId = "post_id"
        case postTs = "post_ts"
    }

    public var signingBytes: [UInt8] {
        Array("ego/dao-chat/delete/v1\n\(from)\n\(postId)\n\(postTs)\n\(ts)".utf8)
    }
}

/// One person's reaction to a post; an empty emoji takes it back.
public struct ChatReact: Codable, Equatable {
    public let from: String
    public let postId: String
    public let postTs: Int64
    public let emoji: String
    public let ts: Int64
    public var pubkey: String
    public var sig: String

    enum CodingKeys: String, CodingKey {
        case from, emoji, ts, pubkey, sig
        case postId = "post_id"
        case postTs = "post_ts"
    }

    public var signingBytes: [UInt8] {
        Array("ego/dao-chat/react/v1\n\(from)\n\(postId)\n\(postTs)\n\(ts)\n\(emoji)".utf8)
    }
}

/// A profile picture: an Ego Storage share link to the image, or empty to remove it.
public struct ChatAvatar: Codable, Equatable {
    public let from: String
    public let link: String
    public let ts: Int64
    public var pubkey: String
    public var sig: String

    public var signingBytes: [UInt8] {
        Array("ego/dao-chat/avatar/v1\n\(from)\n\(ts)\n\(link)".utf8)
    }
}

public enum ChatWire: Encodable, Equatable {
    case post(ChatPost)
    case vote(ChatVote)
    case name(ChatName)
    case edit(ChatEdit)
    case delete(ChatDelete)
    case react(ChatReact)
    case avatar(ChatAvatar)

    private enum KindKey: String, CodingKey { case kind }

    public func encode(to encoder: Encoder) throws {
        var kind = encoder.container(keyedBy: KindKey.self)
        switch self {
        case .post(let p): try kind.encode("post", forKey: .kind); try p.encode(to: encoder)
        case .vote(let v): try kind.encode("vote", forKey: .kind); try v.encode(to: encoder)
        case .name(let n): try kind.encode("name", forKey: .kind); try n.encode(to: encoder)
        case .edit(let e): try kind.encode("edit", forKey: .kind); try e.encode(to: encoder)
        case .delete(let d): try kind.encode("delete", forKey: .kind); try d.encode(to: encoder)
        case .react(let r): try kind.encode("react", forKey: .kind); try r.encode(to: encoder)
        case .avatar(let a): try kind.encode("avatar", forKey: .kind); try a.encode(to: encoder)
        }
    }
}

public enum ChatSigner {
    private static func sign(_ bytes: [UInt8], key: EgoKey) throws -> (String, String) {
        (Hex.encode(key.publicKey), Hex.encode(try key.sign(bytes)))
    }

    public static func post(key: EgoKey, name: String, body: String, ts: Int64) throws -> ChatPost {
        var p = ChatPost(from: key.address, name: name, body: body, ts: ts, pubkey: "", sig: "")
        (p.pubkey, p.sig) = try sign(p.signingBytes, key: key)
        return p
    }

    public static func vote(key: EgoKey, target: String, ts: Int64) throws -> ChatVote {
        var v = ChatVote(voter: key.address, target: target, ts: ts, pubkey: "", sig: "")
        (v.pubkey, v.sig) = try sign(v.signingBytes, key: key)
        return v
    }

    public static func name(key: EgoKey, name: String, ts: Int64) throws -> ChatName {
        var n = ChatName(from: key.address, name: name, ts: ts, pubkey: "", sig: "")
        (n.pubkey, n.sig) = try sign(n.signingBytes, key: key)
        return n
    }

    public static func edit(key: EgoKey, postId: String, postTs: Int64, body: String, ts: Int64) throws -> ChatEdit {
        var e = ChatEdit(from: key.address, postId: postId, postTs: postTs, body: body, ts: ts, pubkey: "", sig: "")
        (e.pubkey, e.sig) = try sign(e.signingBytes, key: key)
        return e
    }

    public static func delete(key: EgoKey, postId: String, postTs: Int64, ts: Int64) throws -> ChatDelete {
        var d = ChatDelete(from: key.address, postId: postId, postTs: postTs, ts: ts, pubkey: "", sig: "")
        (d.pubkey, d.sig) = try sign(d.signingBytes, key: key)
        return d
    }

    public static func react(key: EgoKey, postId: String, postTs: Int64, emoji: String, ts: Int64) throws -> ChatReact {
        var r = ChatReact(from: key.address, postId: postId, postTs: postTs, emoji: emoji, ts: ts, pubkey: "", sig: "")
        (r.pubkey, r.sig) = try sign(r.signingBytes, key: key)
        return r
    }

    public static func avatar(key: EgoKey, link: String, ts: Int64) throws -> ChatAvatar {
        var a = ChatAvatar(from: key.address, link: link, ts: ts, pubkey: "", sig: "")
        (a.pubkey, a.sig) = try sign(a.signingBytes, key: key)
        return a
    }
}

/// What a message is made of: text, code between ``` fences, and photos, videos or GIFs
/// shared as Ego Storage links on their own line.
public enum ChatPart: Equatable {
    case text(String)
    case code(language: String, code: String)
    case media(EgoShareLink)
}

public enum ChatContent {
    public static func parse(_ body: String) -> [ChatPart] {
        var parts: [ChatPart] = []
        var text: [Substring] = []
        var code: [Substring]?
        var language = ""
        func flushText() {
            let joined = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { parts.append(.text(joined)) }
            text = []
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed == "```" {
                    parts.append(.code(language: language, code: open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
            } else if trimmed.hasPrefix("```") {
                flushText()
                language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                code = []
            } else if trimmed.hasPrefix("egoshare1:"), let link = try? EgoShareLink(parsing: trimmed) {
                flushText()
                parts.append(.media(link))
            } else {
                text.append(line)
            }
        }
        // An unclosed fence still shows as code.
        if let open = code { parts.append(.code(language: language, code: open.joined(separator: "\n"))) }
        flushText()
        return parts
    }

    /// A short message of only emoji, shown large.
    public static func isOnlyEmoji(_ body: String) -> Bool {
        let chars = body.filter { !$0.isWhitespace }
        return !chars.isEmpty && chars.count <= 6 && chars.allSatisfy { c in
            c.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0xFF) }
        }
    }

    public static func isReactionEmoji(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.count <= 16
            && !s.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control || ($0.isASCII && $0.properties.isAlphabetic) || ($0.value >= 0x30 && $0.value <= 0x39) }
    }
}
