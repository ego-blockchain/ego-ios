import Foundation
#if canImport(EgoWalletCore)
import EgoWalletCore
#endif

/// The wallet's ML-DSA-44 (Dilithium) key, made from the Ego seed by ego-wallet-core
/// exactly as Ego Desktop makes it, so the same 24 words pin the same key on both.
public enum Dilithium {
    public enum Failure: Error, Equatable {
        case library(String)
        case unavailable
    }

    public struct Signed: Equatable {
        public let publicKey: [UInt8]
        public let signature: [UInt8]
    }

    public static func publicKey(seed: [UInt8]) throws -> [UInt8] {
        #if canImport(EgoWalletCore)
        let json: String = seed.withUnsafeBufferPointer { s in
            guard let raw = ego_wallet_dilithium_public_key(s.baseAddress, s.count) else { return "" }
            defer { ego_wallet_string_free(raw) }
            return String(cString: raw)
        }
        return try field("public_key", in: json)
        #else
        throw Failure.unavailable
        #endif
    }

    /// Signs `message` deterministically with an empty context, as Ego Desktop signs transactions.
    public static func sign(seed: [UInt8], message: [UInt8]) throws -> Signed {
        #if canImport(EgoWalletCore)
        let json: String = seed.withUnsafeBufferPointer { s in
            message.withUnsafeBufferPointer { m in
                guard let raw = ego_wallet_dilithium_sign(s.baseAddress, s.count, m.baseAddress, m.count) else { return "" }
                defer { ego_wallet_string_free(raw) }
                return String(cString: raw)
            }
        }
        return Signed(publicKey: try publicKey(seed: seed), signature: try field("signature", in: json))
        #else
        throw Failure.unavailable
        #endif
    }

    private static func field(_ name: String, in json: String) throws -> [UInt8] {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        if let hex = object?[name], let bytes = Hex.decode(hex) { return bytes }
        throw Failure.library(object?["error"] ?? "no answer")
    }
}
