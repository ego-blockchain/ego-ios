import Foundation
#if canImport(EgoWalletCore)
import EgoWalletCore
#endif

public enum EgoAI {
    public static func answer(_ question: String, after lastQuestion: String?) -> String? {
        #if canImport(EgoWalletCore)
        let json: String = question.withCString { q in
            (lastQuestion ?? "").withCString { l in
                guard let raw = ego_ai_answer(q, l) else { return "" }
                defer { ego_wallet_string_free(raw) }
                return String(cString: raw)
            }
        }
        struct Answer: Decodable { let answer: String? }
        return (try? JSONDecoder().decode(Answer.self, from: Data(json.utf8)))?.answer
        #else
        return nil
        #endif
    }

    public struct StarterGroup: Hashable, Sendable {
        public let heading: String
        public let questions: [String]
    }

    public static let starters: [StarterGroup] = [
        StarterGroup(heading: "Start here", questions: [
            "What is a dApp?",
            "How do I create a dApp?",
            "How do I build an app with a smart contract and launch it on my website?",
        ]),
        StarterGroup(heading: "Smart contracts", questions: [
            "Show me a smart contract example",
            "Why should I use Urego?",
            "How do I deploy a contract?",
        ]),
        StarterGroup(heading: "Using Ego", questions: [
            "What is Ego?",
            "How do I earn EGOC?",
            "How does staking work?",
        ]),
        StarterGroup(heading: "Safety & developers", questions: [
            "What happens if my coins are stolen?",
            "Where is the developer API?",
        ]),
    ]

    static let followUps: [(topic: String, questions: [String])] = [
        ("stolen|theft|steal|hack|freeze", [
            "What happens if my coins are stolen?",
            "How does DAO voting work?",
        ]),
        ("\\bapi\\b|rpc|json|endpoint|window\\.ego|gateway", [
            "Where is the developer API?",
            "How do I run a node?",
            "How do I deploy a contract?",
        ]),
        ("dapp|decentrali[sz]ed app|web3 app", [
            "Show me a smart contract example",
            "How do I build an app with a smart contract and launch it on my website?",
            "What is the dApp IDE?",
        ]),
        ("contract|urego|deploy|compile|ide", [
            "Why should I use Urego?",
            "How do I deploy a contract?",
            "How do I host a website?",
            "What is a dApp?",
        ]),
        ("earn|income|reward|stake|staking|apr|mining", [
            "How does Proof of Coverage work?",
            "What is DRS reward scoring?",
            "How do I run a node?",
        ]),
        ("consensus|bft|shard|block|validator|node", [
            "How does sharding work?",
            "What is in a block header?",
            "What is the security model?",
        ]),
        ("token|supply|price|egusd|egoc|fee|gas", [
            "Explain the tokenomics",
            "What is EGUSD?",
            "How do transaction fees work?",
        ]),
        ("storage|file|egosafe|messenger|chat|privacy", [
            "How does Proof of Storage work?",
            "What is PoRep?",
            "How does the messenger stay private?",
        ]),
    ]

    static let fallbackFollowUps = [
        "What is a dApp?",
        "How do I create a dApp?",
        "Show me a smart contract example",
        "How do I earn EGOC?",
    ]

    public static func followUps(after lastQuestion: String, asked: [String]) -> [String] {
        let done = Set(asked.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let range = NSRange(lastQuestion.startIndex..., in: lastQuestion)
        let pool = followUps.first { group in
            (try? NSRegularExpression(pattern: group.topic, options: [.caseInsensitive]))?.firstMatch(in: lastQuestion, range: range) != nil
        }?.questions ?? fallbackFollowUps
        let fresh = pool.filter { !done.contains($0.lowercased()) }
        let chosen = fresh.isEmpty ? fallbackFollowUps.filter { !done.contains($0.lowercased()) } : fresh
        return Array(chosen.prefix(3))
    }
}
