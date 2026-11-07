import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum Totp {
    public static let period: Int64 = 30
    public static let digits = 6
    public static let secretBytes = 20

    public static func code(secret: Data, step: Int64) -> UInt32 {
        var counter = UInt64(bitPattern: step).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let bin = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        return bin % 1_000_000
    }

    public static func matchingStep(secret: Data, entered: String, now: Int64) -> Int64? {
        let cleaned = entered.filter { !$0.isWhitespace }
        guard cleaned.count == digits, cleaned.allSatisfy({ $0.isASCII && $0.isNumber }), let want = UInt32(cleaned) else {
            return nil
        }
        let t = now >= 0 ? now / period : (now - period + 1) / period
        return [t, t - 1, t + 1].first { code(secret: secret, step: $0) == want }
    }

    public static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 {
            out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
        }
        return out
    }

    public static func newSecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<secretBytes).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    public static func setupURI(secret: Data, address: String, issuer: String = "Ego Wallet") -> String {
        let label = address.count > 16 ? "\(address.prefix(10))...\(address.suffix(4))" : address
        let issuerEscaped = issuer.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Ego"
        return "otpauth://totp/\(issuerEscaped):\(label)?secret=\(base32(secret))&issuer=\(issuerEscaped)&algorithm=SHA1&digits=\(digits)&period=\(period)"
    }
}
