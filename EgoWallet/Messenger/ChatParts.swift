import AVKit
import EgoKit
import ImageIO
import SwiftUI
import UIKit

struct ChatAttachment: Equatable {
    let name: String
    let data: Data
    let preview: UIImage?
    var isVideo: Bool { LibraryFile.Kind.of(name: name) == .video }
}

struct DayDivider: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(Brand.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
            .padding(.vertical, 10)
    }

    private var label: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

struct ChatMedia: View {
    let link: EgoShareLink
    var onOpen: (URL) -> Void = { _ in }
    @EnvironmentObject private var storage: StorageStore
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    private var kind: LibraryFile.Kind { LibraryFile.Kind.of(name: link.name) }
    private var isGIF: Bool { (link.name as NSString).pathExtension.lowercased() == "gif" }

    var body: some View {
        Button {
            if let url { onOpen(url) } else if failed { failed = false; Task { await load() } }
        } label: {
            ZStack {
                if let image {
                    if isGIF, let url {
                        AnimatedImage(url: url)
                            .aspectRatio(image.size, contentMode: .fit)
                    } else {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                } else {
                    Rectangle().fill(Brand.raised.opacity(0.8))
                        .frame(width: 220, height: kind == .document ? 70 : 160)
                    VStack(spacing: 6) {
                        if failed {
                            Image(systemName: "arrow.clockwise").font(.title3)
                            Text("Couldn't load · tap to retry").font(.caption2)
                        } else if kind == .document {
                            Label(link.name, systemImage: "doc.fill").font(.caption.weight(.bold)).lineLimit(1).padding(.horizontal, 10)
                        } else {
                            ProgressView().tint(Brand.sky)
                        }
                    }
                    .foregroundStyle(Brand.muted)
                }
                if kind == .video, image != nil {
                    Image(systemName: "play.fill")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .frame(maxWidth: 240, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind == .video ? "Video, \(link.name)" : kind == .photo ? "Photo, \(link.name)" : link.name)
        .task(id: link.cid) { await load() }
    }

    private func load() async {
        do {
            let file = try await storage.openShared(link)
            url = file
            switch kind {
            case .photo:
                image = await Task.detached { UIImage(contentsOfFile: file.path).map { $0.preparingThumbnail(of: CGSize(width: 720, height: 720)) ?? $0 } }.value
            case .video:
                image = await Task.detached {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 720, height: 720)
                    return (try? await generator.image(at: .zero).image).map(UIImage.init(cgImage:))
                }.value
            case .document:
                break
            }
        } catch {
            failed = true
        }
    }
}

struct AnimatedImage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = Self.animated(url)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}

    static func animated(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), 300)
        var frames: [UIImage] = []
        var duration = 0.0
        for i in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, i, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
            ] as CFDictionary) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(delay, 0.02)
            frames.append(UIImage(cgImage: frame))
        }
        return frames.count > 1 ? UIImage.animatedImage(with: frames, duration: duration) : frames.first
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Brand.muted)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Haptics.tap()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.sky)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlight(code))
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color(red: 0.05, green: 0.06, blue: 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.violet.opacity(0.35)))
    }
}

enum CodeHighlighter {
    static let keywords: Set<String> = [
        "let", "var", "const", "func", "fn", "function", "def", "class", "struct", "enum", "impl", "trait", "interface",
        "return", "if", "else", "for", "while", "in", "match", "switch", "case", "break", "continue", "import", "from",
        "pub", "use", "mod", "async", "await", "try", "catch", "throw", "throws", "guard", "self", "Self", "this",
        "true", "false", "nil", "null", "None", "Some", "Ok", "Err", "mut", "static", "public", "private", "new",
        "type", "where", "do", "loop", "and", "or", "not", "elif", "lambda", "pass", "yield", "contract", "mapping",
        "uint", "uint256", "address", "string", "bool", "int", "u64", "i64", "u8", "String", "Vec",
    ]

    static func highlight(_ code: String) -> AttributedString {
        var out = AttributedString()
        let chars = Array(code)
        var i = 0
        func emit(_ s: String, _ color: Color) {
            var piece = AttributedString(s)
            piece.foregroundColor = color
            out += piece
        }
        while i < chars.count {
            let c = chars[i]
            if (c == "/" && i + 1 < chars.count && chars[i + 1] == "/") || c == "#" {
                var j = i
                while j < chars.count && chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), Color(red: 0.45, green: 0.52, blue: 0.62))
                i = j
            } else if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count && chars[j] != c && chars[j] != "\n" {
                    j += chars[j] == "\\" ? 2 : 1
                }
                j = min(j + 1, chars.count)
                emit(String(chars[i..<j]), Color(red: 0.98, green: 0.78, blue: 0.45))
                i = j
            } else if c.isNumber {
                var j = i
                while j < chars.count && (chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j] == "x" || chars[j].isHexDigit) { j += 1 }
                emit(String(chars[i..<j]), Brand.pink)
                i = j
            } else if c.isLetter || c == "_" {
                var j = i
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                let word = String(chars[i..<j])
                let isCall = j < chars.count && chars[j] == "("
                emit(word, keywords.contains(word) ? Brand.violet.opacity(1) : isCall ? Brand.sky : (word.first?.isUppercase == true ? Brand.mint : Brand.text))
                i = j
            } else {
                emit(String(c), Brand.text.opacity(0.85))
                i += 1
            }
        }
        return out
    }
}

struct ProfilePicture: View {
    let link: String
    let fallback: String
    let address: String
    var size: CGFloat = 30
    @EnvironmentObject private var storage: StorageStore
    @State private var image: UIImage?

    var body: some View {
        let base = Self.color(for: address)
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [base, base.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String((fallback.isEmpty ? String(address.dropFirst(5)) : fallback).prefix(1)).uppercased())
                    .font(.system(size: size * 0.43, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.2)))
        .accessibilityHidden(true)
        .task(id: link) {
            image = nil
            guard let parsed = try? EgoShareLink(parsing: link),
                  let url = try? await storage.openShared(parsed) else { return }
            image = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 160, height: 160)) }.value
        }
    }

    static func color(for address: String) -> Color {
        let hue = Double(address.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.95)
    }
}
