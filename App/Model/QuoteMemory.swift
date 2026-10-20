import Foundation
import HermesKit

/// Where this device's quotes came from (`docs/inbox.md` §4 Reply with a quote): per chat, a
/// quote's key (a hash, never its words) → who said it and the row it's in. Elsewhere the quote
/// is plain.
enum QuoteMemory {
    struct Source: Codable, Equatable {
        var author: String
        var rowID: String
    }

    private static let limit = 200

    private static func key(_ chat: String) -> String { "quotes.\(chat)" }

    static func remember(_ quote: String, author: String, rowID: String, chat: String) {
        var all = load(chat)
        all[QuotedReply.key(quote)] = Source(author: author, rowID: rowID)
        if all.count > limit { all = Dictionary(uniqueKeysWithValues: all.shuffled().prefix(limit).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key(chat)) }
    }

    static func source(of quote: String, chat: String?) -> Source? {
        guard let chat else { return nil }
        return load(chat)[QuotedReply.key(quote)]
    }

    private static func load(_ chat: String) -> [String: Source] {
        UserDefaults.standard.data(forKey: key(chat)).flatMap { try? JSONDecoder().decode([String: Source].self, from: $0) } ?? [:]
    }
}
