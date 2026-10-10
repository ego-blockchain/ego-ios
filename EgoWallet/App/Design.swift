import SwiftUI
import UIKit

// The shared look of Ego Wallet's flows: a living background, a glowing mark,
// a step header, glass fields, a review card, hold-to-confirm and a success burst.

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func firm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

extension Brand {
    static let violet = Color(red: 0.49, green: 0.36, blue: 1.0)
    static let glow = LinearGradient(colors: [Brand.lime, Brand.mint], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Slow drifting light behind the dark background.
struct AuroraBackground: View {
    var intensity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Brand.ink
                    blob(Brand.lime, size: w * 0.9, x: w * (0.15 + 0.12 * sin(t * 0.11)), y: h * (0.12 + 0.06 * cos(t * 0.09)), opacity: 0.22)
                    blob(Brand.mint, size: w * 0.8, x: w * (0.85 + 0.10 * cos(t * 0.07)), y: h * (0.38 + 0.08 * sin(t * 0.13)), opacity: 0.16)
                    blob(Brand.violet, size: w * 1.0, x: w * (0.30 + 0.15 * sin(t * 0.05 + 1)), y: h * (0.92 + 0.05 * cos(t * 0.08)), opacity: 0.20)
                }
            }
        }
        .ignoresSafeArea()
        .opacity(intensity)
        .background(Brand.ink.ignoresSafeArea())
    }

    private func blob(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: size, height: size)
            .blur(radius: size * 0.28)
            .position(x: x, y: y)
    }
}

/// The Ego mark with a turning ring of light and a soft pulse.
struct GlowingMark: View {
    var size: CGFloat = 88
    @State private var spin = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(Brand.lime.opacity(0.18))
                .frame(width: size * 1.7, height: size * 1.7)
                .blur(radius: size * 0.35)
                .scaleEffect(pulse ? 1.12 : 0.9)
            Circle()
                .stroke(
                    AngularGradient(colors: [Brand.lime, Brand.mint, Brand.violet.opacity(0.6), .clear, Brand.lime], center: .center),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: size * 1.45, height: size * 1.45)
                .rotationEffect(.degrees(spin ? 360 : 0))
            Circle()
                .fill(Brand.card.opacity(0.85))
                .frame(width: size * 1.25, height: size * 1.25)
                .overlay(Circle().stroke(Color.white.opacity(0.06)))
            EgoMark(size: size * 0.72)
                .shadow(color: Brand.lime.opacity(0.55), radius: 16)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

/// A view that rises and fades in after `delay`.
struct Reveal: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(delay)) { shown = true } }
    }
}

extension View {
    func reveal(_ delay: Double = 0) -> some View { modifier(Reveal(delay: delay)) }
}

/// Details → Review → Done.
struct StepDots: View {
    let step: Int
    var labels = ["Details", "Review", "Done"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? AnyShapeStyle(Brand.glow) : AnyShapeStyle(Color.white.opacity(0.12)))
                    .frame(width: i == step ? 26 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of \(labels.count): \(labels[min(step, labels.count - 1)])")
    }
}

/// The page every money flow uses: header, content, and a pinned action area.
struct FlowSheet<Content: View, Footer: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var step: Int?
    var tint: Color = Brand.lime
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.7)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Brand.muted)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        content()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                VStack(spacing: 10) { footer() }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    .background(.ultraThinMaterial.opacity(0.9))
                    .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1), alignment: .top)
            }
        }
        .presentationBackground(Brand.ink)
        .presentationCornerRadius(28)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 74, height: 74).blur(radius: 14)
                Circle()
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 60, height: 60)
                    .overlay(Circle().stroke(tint.opacity(0.45), lineWidth: 1))
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, value: step ?? 0)
            }
            Text(title)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(Brand.text)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
            }
            if let step { StepDots(step: step) }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }
}

/// A frosted card with a small label.
struct GlassField<Content: View>: View {
    let label: String
    var icon: String?
    var trailing: AnyView?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(Brand.lime)
                }
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(Brand.muted)
                Spacer()
                trailing
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(Brand.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
        )
    }
}

/// An address field with paste, checked as you type.
struct AddressInput: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var problem: String?

    var body: some View {
        GlassField(label: label, icon: "person.crop.circle", trailing: AnyView(
            Button {
                text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text
                Haptics.tap()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Brand.lime)
        )) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Brand.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)
            if let problem, !text.isEmpty {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Brand.danger)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: problem)
    }
}

/// A large centred amount with its unit, and optional quick picks under it.
struct AmountInput: View {
    let label: String
    let unit: String
    @Binding var text: String
    var caption: String?
    var problem: String?
    var quickPicks: [(String, String)] = []
    @FocusState private var focused: Bool

    var body: some View {
        GlassField(label: label, icon: "number") {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(Brand.text)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(unit)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Brand.lime)
                }
                .frame(maxWidth: .infinity)
                if let caption {
                    Text(caption).font(.footnote).foregroundStyle(Brand.muted)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(Brand.danger)
                }
                if !quickPicks.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(quickPicks, id: \.0) { pick in
                            Button(pick.0) {
                                text = pick.1
                                Haptics.tap()
                            }
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Brand.lime.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(Brand.lime.opacity(0.35)))
                            .foregroundStyle(Brand.lime)
                        }
                    }
                }
            }
        }
        .onTapGesture { focused = true }
    }
}

/// What will happen, in rows, with the bottom line set apart.
struct SummaryCard: View {
    struct Row: Identifiable {
        let label: String
        let value: String
        var mono = false
        var id: String { label }
    }

    let rows: [Row]
    var total: Row?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                HStack(alignment: .top) {
                    Text(row.label).foregroundStyle(Brand.muted)
                    Spacer(minLength: 16)
                    Text(row.value)
                        .font(row.mono ? .system(.subheadline, design: .monospaced) : .subheadline.weight(.semibold))
                        .foregroundStyle(Brand.text)
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .padding(.vertical, 12)
                if i < rows.count - 1 || total != nil {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                }
            }
            if let total {
                HStack {
                    Text(total.label).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.text)
                    Spacer()
                    Text(total.value)
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .foregroundStyle(Brand.glow)
                }
                .padding(.top, 14)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Brand.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.1)))
    }
}

/// Press and hold to send: money only moves after a deliberate second.
struct HoldToConfirm: View {
    let title: String
    var busyTitle = "Sending…"
    var busy = false
    var enabled = true
    let action: () -> Void

    @State private var progress: CGFloat = 0
    @State private var holding = false
    private let duration = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Brand.raised)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Brand.glow)
                    .frame(width: max(0, geo.size.width * (busy ? 1 : progress)))
                HStack(spacing: 10) {
                    if busy {
                        ProgressView().tint(Brand.ink)
                    } else {
                        Image(systemName: holding ? "lock.open.fill" : "hand.tap.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    Text(busy ? busyTitle : holding ? "Keep holding…" : title)
                        .font(.system(.headline, design: .rounded))
                }
                .foregroundStyle(busy || progress > 0.5 ? Brand.ink : Brand.text)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 58)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Brand.lime.opacity(enabled ? 0.45 : 0.1)))
        .opacity(enabled || busy ? 1 : 0.45)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 60) {
            guard enabled, !busy else { return }
            holding = false
            Haptics.success()
            action()
            withAnimation(.easeOut(duration: 0.3)) { progress = 0 }
        } onPressingChanged: { pressing in
            guard enabled, !busy else { return }
            holding = pressing
            if pressing {
                Haptics.firm()
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else if progress < 1 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { progress = 0 }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityHint("Double tap to confirm")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled && !busy { action() } }
    }
}

/// A big glowing primary button for the steps before confirming.
struct GlowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Brand.glow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(Brand.ink)
            .shadow(color: Brand.lime.opacity(isEnabled ? 0.35 : 0), radius: 14, y: 6)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A quiet text button under the main one.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(Brand.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A drawn ring, a check that pops, and a burst of light.
struct SuccessBurst: View {
    let title: String
    var subtitle: String?
    @State private var drawn: CGFloat = 0
    @State private var popped = false
    @State private var burst = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<14, id: \.self) { i in
                    let angle = Double(i) / 14 * 2 * .pi
                    Circle()
                        .fill(i.isMultiple(of: 2) ? Brand.lime : Brand.mint)
                        .frame(width: 7, height: 7)
                        .offset(x: burst ? cos(angle) * 78 : 0, y: burst ? sin(angle) * 78 : 0)
                        .opacity(burst ? 0 : 1)
                }
                Circle()
                    .trim(from: 0, to: drawn)
                    .stroke(Brand.glow, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(Brand.lime)
                    .scaleEffect(popped ? 1 : 0.2)
                    .opacity(popped ? 1 : 0)
            }
            .frame(height: 170)
            Text(title)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(Brand.text)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(Brand.muted).multilineTextAlignment(.center)
            }
        }
        .onAppear {
            Haptics.success()
            if reduceMotion {
                drawn = 1; popped = true; burst = true
                return
            }
            withAnimation(.easeOut(duration: 0.55)) { drawn = 1 }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.4)) { popped = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.45)) { burst = true }
        }
    }
}

/// A transaction hash with copy and an optional explorer link.
struct HashCard: View {
    let hash: String
    var explorer: URL?
    @State private var copied = false

    var body: some View {
        GlassField(label: "Transaction", icon: "number.square") {
            Text(hash)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Brand.text)
                .textSelection(.enabled)
            HStack(spacing: 16) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = hash
                    copied = true
                    Haptics.tap()
                }
                if let explorer {
                    Link("View on explorer", destination: explorer)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Brand.lime)
        }
    }
}

/// A short note in the flow, informational or a warning.
struct NoteCard: View {
    let text: String
    var icon = "info.circle.fill"
    var tint: Color = Brand.muted

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(tint)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A frosted capsule switch between a few options.
struct GlassSegments<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = option }
                    Haptics.tap()
                } label: {
                    Text(title(option))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(on ? Brand.ink : Brand.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if on { Capsule().fill(Brand.glow).matchedGeometryEffect(id: "pill", in: pill) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.ultraThinMaterial.opacity(0.55), in: Capsule())
        .background(Brand.card.opacity(0.6), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1)))
    }
}

/// Small selectable chips, such as the coin to pay with.
struct ChipPicker: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let on = option == selection
                    Button {
                        withAnimation(.spring(response: 0.3)) { selection = option }
                        Haptics.tap()
                    } label: {
                        Text(option)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(on ? AnyShapeStyle(Brand.glow) : AnyShapeStyle(Color.white.opacity(0.06)), in: Capsule())
                            .overlay(Capsule().stroke(on ? Color.clear : Color.white.opacity(0.12)))
                            .foregroundStyle(on ? Brand.ink : Brand.text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

extension View {
    /// A text field set into a glass card.
    func glassInput() -> some View {
        self
            .foregroundStyle(Brand.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1)))
    }
}

/// An outlined button for actions inside a card.
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .foregroundStyle(Brand.lime)
            .background(Brand.lime.opacity(configuration.isPressed ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.lime.opacity(0.4)))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A pushed page in the same look as the flows: aurora behind, cards in a column.
struct GlassPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.7)
            ScrollView {
                VStack(spacing: 16) { content() }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// Lays out chips left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
