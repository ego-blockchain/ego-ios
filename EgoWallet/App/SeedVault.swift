import Foundation
@preconcurrency import LocalAuthentication
import Security

enum VaultError: LocalizedError {
    case keychain(OSStatus)
    case cancelled
    case noPasscode
    case missing

    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "The iPhone keychain refused the request (code \(status))."
        case .cancelled: return "Unlock was cancelled."
        case .noPasscode: return "Set a passcode on this iPhone first. Ego Wallet keeps your recovery key behind it."
        case .missing: return "This iPhone no longer has your wallet's key. iOS deletes it if the passcode is turned off. Your coins are safe: restore the wallet with its 24 words or raw seed."
        }
    }
}

struct SeedVault {
    private let service = "com.egoblockchain.wallet"
    private let account = "seed"
    private let addressKey = "ego.wallet.address"

    var storedAddress: String? {
        UserDefaults.standard.string(forKey: addressKey)
    }

    func store(seed: [UInt8], address: String) throws {
        delete()
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            throw VaultError.noPasscode
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data(seed),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecNotAvailable || status == errSecAuthFailed {
            throw VaultError.noPasscode
        }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        UserDefaults.standard.set(address, forKey: addressKey)
    }

    /// Asks for Face ID, or the passcode if Face ID isn't available. Passing
    /// the context to readSeed then opens the keychain without asking again.
    func authenticate(reason: String) async throws -> LAContext {
        let context = LAContext()
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return context
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            throw VaultError.cancelled
        } catch let error as LAError where error.code == .passcodeNotSet {
            throw VaultError.noPasscode
        }
    }

    func readSeed(reason: String, context given: LAContext? = nil) async throws -> [UInt8] {
        let service = self.service
        let account = self.account
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = given ?? LAContext()
                context.localizedReason = reason
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseAuthenticationContext as String: context,
                ]
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecSuccess, let data = item as? Data, data.count == 32 {
                    continuation.resume(returning: [UInt8](data))
                } else if status == errSecUserCanceled {
                    continuation.resume(throwing: VaultError.cancelled)
                } else if status == errSecItemNotFound {
                    continuation.resume(throwing: VaultError.missing)
                } else {
                    continuation.resume(throwing: VaultError.keychain(status))
                }
            }
        }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: addressKey)
    }
}
