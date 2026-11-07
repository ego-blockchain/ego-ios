import EgoKit
import Foundation
import Security
import SwiftUI

@MainActor
final class Authenticator: ObservableObject {
    static let shared = Authenticator()

    enum Action {
        case send
        case reveal
    }

    struct Request: Identifiable {
        let id = UUID()
        let action: Action
        let resume: (Bool) -> Void
    }

    enum Check: Equatable {
        case ok
        case wrong
        case reused
        case locked(minutes: Int)
    }

    @Published private(set) var enabled = false

    /// How long the wallet stays unlocked while its owner fetches a code from another app.
    static let codeTripSeconds: TimeInterval = 180
    /// Screens waiting for a code right now. Leaving for the authenticator app
    /// doesn't lock the wallet while any are open, so they're still there on return.
    private var waiting: Set<String> = []
    var awaitingCode: Bool { !waiting.isEmpty }

    func waitForCode(_ who: String, _ on: Bool) {
        if on { waiting.insert(who) } else { waiting.remove(who) }
    }
    private var fails = 0
    private var lockedUntil = Date.distantPast
    private let service = "com.egoblockchain.wallet"
    private let account = "totp"
    private let lastStepKey = "ego.totp.lastStep"
    private let maxFails = 5
    private let lockSeconds: TimeInterval = 300

    init() {
        enabled = readSecret() != nil
    }

    func check(_ entered: String) -> Check {
        let now = Date()
        if now < lockedUntil {
            return .locked(minutes: Int((lockedUntil.timeIntervalSince(now) / 60).rounded(.up)))
        }
        guard let secret = readSecret(),
              let step = Totp.matchingStep(secret: secret, entered: entered, now: Int64(now.timeIntervalSince1970))
        else {
            fails += 1
            if fails >= maxFails {
                lockedUntil = now.addingTimeInterval(lockSeconds)
                fails = 0
            }
            return .wrong
        }
        let last = Int64(UserDefaults.standard.integer(forKey: lastStepKey))
        guard step > last else { return .reused }
        UserDefaults.standard.set(Int(step), forKey: lastStepKey)
        fails = 0
        return .ok
    }

    func turnOn(secret: Data, entered: String) -> Bool {
        guard let step = Totp.matchingStep(secret: secret, entered: entered, now: Int64(Date().timeIntervalSince1970)),
              writeSecret(secret)
        else { return false }
        UserDefaults.standard.set(Int(step), forKey: lastStepKey)
        enabled = true
        return true
    }

    func turnOff(entered: String) -> Check {
        let result = check(entered)
        if result == .ok { forget() }
        return result
    }

    func forget() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: lastStepKey)
        enabled = false
    }

    private func readSecret() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == Totp.secretBytes else {
            return nil
        }
        return data
    }

    private func writeSecret(_ secret: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = secret
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

@MainActor
final class AuthGate: ObservableObject {
    @Published var pending: Authenticator.Request?

    private lazy var id = "gate-\(ObjectIdentifier(self).hashValue)"

    func require(_ action: Authenticator.Action) async -> Bool {
        guard Authenticator.shared.enabled else { return true }
        Authenticator.shared.waitForCode(id, true)
        return await withCheckedContinuation { continuation in
            pending = Authenticator.Request(action: action) { continuation.resume(returning: $0) }
        }
    }

    func finish(_ ok: Bool) {
        let request = pending
        pending = nil
        Authenticator.shared.waitForCode(id, false)
        request?.resume(ok)
    }
}

struct AuthGateSheet: ViewModifier {
    @ObservedObject var gate: AuthGate

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { gate.pending }, set: { if $0 == nil { gate.finish(false) } })) { request in
            AuthenticatorPrompt(gate: gate, request: request)
                .presentationDetents([.medium])
        }
    }
}

extension View {
    func authGate(_ gate: AuthGate) -> some View {
        modifier(AuthGateSheet(gate: gate))
    }
}

struct AuthenticatorPrompt: View {
    @ObservedObject var gate: AuthGate
    let request: Authenticator.Request
    @State private var entered = ""
    @State private var problem: String?

    var body: some View {
        FlowSheet(icon: "lock.shield.fill", title: request.action == .send ? "Confirm this payment" : "Confirm it's you",
                  subtitle: "Enter the 6-digit code from your authenticator app.") {
            GlassField(label: "Code", icon: "number") {
                TextField("000000", text: $entered)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.title2, design: .monospaced))
                    .onChange(of: entered) { _, value in
                        let digits = String(value.filter(\.isNumber).prefix(Totp.digits))
                        if digits != value { entered = digits }
                    }
            }
            if let problem {
                NoteCard(text: problem, icon: "exclamationmark.triangle.fill", tint: Brand.danger)
            }
        } footer: {
            Button("Confirm") { confirm() }
                .buttonStyle(GlowButtonStyle())
                .disabled(entered.count != Totp.digits)
        }
    }

    private func confirm() {
        switch Authenticator.shared.check(entered) {
        case .ok:
            gate.finish(true)
        case .wrong:
            Haptics.warning()
            problem = "Wrong code."
            entered = ""
        case .reused:
            problem = "That code was already used. Wait for the next one."
            entered = ""
        case .locked(let minutes):
            Haptics.warning()
            problem = "Too many wrong codes. Try again in \(minutes) min."
        }
    }
}

struct AuthenticatorCard: View {
    let address: String
    @ObservedObject private var auth = Authenticator.shared
    @State private var setupSecret: Data?
    @State private var turningOff = false
    @State private var entered = ""
    @State private var problem: String?
    @State private var copied = false

    var body: some View {
        card
            // Setting up and turning off both send the owner to the authenticator app and back.
            .onChange(of: setupSecret != nil || turningOff) { _, on in auth.waitForCode("card", on) }
            .onDisappear { auth.waitForCode("card", false) }
    }

    private var card: some View {
        GlassCard {
            SectionLabel(text: "Authenticator app")
            Text(auth.enabled
                 ? "On. Sending and showing your 24 words need a code from your authenticator app."
                 : "Google Authenticator, Authy or any app with 6-digit codes. Works offline, no account needed. Codes on a second device protect best.")
                .font(.caption)
                .foregroundStyle(Brand.muted)
            if let secret = setupSecret {
                setup(secret)
            } else if turningOff {
                codeField
                HStack {
                    Button("Turn off") { off() }
                        .buttonStyle(OutlineButtonStyle(tint: Brand.danger))
                        .disabled(entered.count != Totp.digits)
                    Button("Cancel") { turningOff = false; entered = ""; problem = nil }
                        .buttonStyle(GhostButtonStyle())
                }
            } else if auth.enabled {
                Button("Turn off") { turningOff = true; entered = ""; problem = nil }
                    .buttonStyle(OutlineButtonStyle())
            } else {
                Button("Turn on") { setupSecret = Totp.newSecret(); entered = ""; problem = nil }
                    .buttonStyle(GlowButtonStyle())
            }
            if let problem {
                NoteCard(text: problem, icon: "exclamationmark.triangle.fill", tint: Brand.danger)
            }
        }
    }

    private var codeField: some View {
        TextField("6-digit code", text: $entered)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(.system(.title3, design: .monospaced))
            .onChange(of: entered) { _, value in
                let digits = String(value.filter(\.isNumber).prefix(Totp.digits))
                if digits != value { entered = digits }
            }
    }

    @ViewBuilder
    private func setup(_ secret: Data) -> some View {
        let uri = Totp.setupURI(secret: secret, address: address)
        if let url = URL(string: uri) {
            Link(destination: url) { Label("Add to an authenticator app on this iPhone", systemImage: "plus.app") }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.lime)
        }
        if let image = QRCode.image(for: uri) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 180, height: 180)
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        }
        Text("Or scan this with an authenticator app on another device. Can't scan? Enter this key:")
            .font(.caption)
            .foregroundStyle(Brand.muted)
        HStack {
            Text(Totp.base32(secret))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Brand.text)
                .textSelection(.enabled)
            Button(copied ? "Copied" : "Copy") {
                UIPasteboard.general.string = Totp.base32(secret)
                copied = true
                Haptics.tap()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Brand.lime)
        }
        Text("Then type the code it shows.")
            .font(.caption)
            .foregroundStyle(Brand.muted)
        codeField
        HStack {
            Button("Turn on") { on(secret) }
                .buttonStyle(GlowButtonStyle())
                .disabled(entered.count != Totp.digits)
            Button("Cancel") { setupSecret = nil; problem = nil }
                .buttonStyle(GhostButtonStyle())
        }
        Text("Keep the key somewhere safe. If you lose the device with your codes, you need it or your 24 words to get back in.")
            .font(.caption2)
            .foregroundStyle(Brand.warning)
    }

    private func on(_ secret: Data) {
        if auth.turnOn(secret: secret, entered: entered) {
            setupSecret = nil
            entered = ""
            problem = nil
        } else {
            Haptics.warning()
            problem = "That code does not match. Check the time on your devices and try the newest code."
            entered = ""
        }
    }

    private func off() {
        switch auth.turnOff(entered: entered) {
        case .ok:
            turningOff = false
            entered = ""
            problem = nil
        case .wrong:
            problem = "Wrong code."
            entered = ""
        case .reused:
            problem = "That code was already used. Wait for the next one."
            entered = ""
        case .locked(let minutes):
            problem = "Too many wrong codes. Try again in \(minutes) min."
        }
    }
}

enum AuthReminder {
    private static let key = "ego.totp.reminderUntil"

    static func due(enabled: Bool) -> Bool {
        !enabled && Date().timeIntervalSince1970 >= UserDefaults.standard.double(forKey: key)
    }

    static func snooze(days: Double) {
        UserDefaults.standard.set(Date().timeIntervalSince1970 + days * 86_400, forKey: key)
    }
}

struct AuthenticatorSetupSheet: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = Authenticator.shared

    var body: some View {
        FlowSheet(icon: "lock.shield.fill", title: "Authenticator app", subtitle: "Adds a 6-digit code to payments and to showing your 24 words") {
            AuthenticatorCard(address: address)
        } footer: {
            Button(auth.enabled ? "Done" : "Not now") { dismiss() }
                .buttonStyle(GlowButtonStyle())
        }
    }
}
