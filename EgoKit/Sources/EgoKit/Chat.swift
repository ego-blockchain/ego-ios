import Foundation

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
        if let open = code { parts.append(.code(language: language, code: open.joined(separator: "\n"))) }
        flushText()
        return parts
    }

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
