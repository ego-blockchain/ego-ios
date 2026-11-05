import Foundation

enum EgoScan {
    static let base = "https://egoblockchain.com/egoscan"

    static func tx(_ hash: String, height: UInt64? = nil) -> URL? {
        url([URLQueryItem(name: "tx", value: hash)] + (height.map { [URLQueryItem(name: "h", value: String($0))] } ?? []))
    }

    static func block(_ height: UInt64) -> URL? {
        url([URLQueryItem(name: "block", value: String(height))])
    }

    static func address(_ address: String) -> URL? {
        address.hasPrefix("ego") ? url([URLQueryItem(name: "address", value: address)]) : nil
    }

    private static func url(_ items: [URLQueryItem]) -> URL? {
        var c = URLComponents(string: base)
        c?.queryItems = items
        return c?.url
    }
}
