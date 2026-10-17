import Foundation

enum WatchlistSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case trakt, letterboxd, tmdb, tvdb

    var id: String { rawValue }

    var name: String {
        switch self {
        case .trakt: return "Trakt"
        case .letterboxd: return "Letterboxd"
        case .tmdb: return "TMDB"
        case .tvdb: return "TheTVDB"
        }
    }
}

/// One title as it appears on an outside watchlist, before it's matched to the Seerr server.
struct WatchlistEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let source: WatchlistSource
    var title: String
    var year: Int?
    var kind: MediaType?
    var tmdbId: Int?
    var imdbId: String?
}

enum WatchlistStatus: Sendable {
    case matching      // not checked against the server yet
    case notFound      // couldn't be matched to a movie or series
    case unchecked     // matched, but the server couldn't be reached
    case missing       // not on the server and not requested
    case partial       // some seasons still requestable
    case requested
    case available
}

/// A watchlist entry matched to Seerr, with its current availability.
struct WatchlistItem: Identifiable, Sendable {
    let entry: WatchlistEntry
    var route: MediaRoute?
    var title: String
    var year: String?
    var posterURL: URL?
    var status: WatchlistStatus

    var id: String { entry.id }
    var canRequest: Bool { status == .missing || status == .partial }

    static func placeholder(_ entry: WatchlistEntry, status: WatchlistStatus = .matching,
                            route: MediaRoute? = nil) -> WatchlistItem {
        WatchlistItem(entry: entry, route: route, title: entry.title,
                      year: entry.year.map(String.init), posterURL: nil, status: status)
    }
}

// MARK: - Helpers shared by the importers

/// Runs `transform` over `items` with at most `limit` running at once, keeping the input order.
func boundedMap<T: Sendable, R: Sendable>(
    _ items: [T], limit: Int, _ transform: @escaping @Sendable (T) async -> R
) async -> [R] {
    guard !items.isEmpty else { return [] }
    return await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(limit, items.count) {
            let index = next, item = items[index]
            next += 1
            group.addTask { (index, await transform(item)) }
        }
        while let (index, value) = await group.next() {
            results[index] = value
            if next < items.count {
                let i = next, item = items[i]
                next += 1
                group.addTask { (i, await transform(item)) }
            }
        }
        return results.map { $0! }
    }
}

/// Plain web page fetches for public watchlist pages. Identifies itself honestly as Mindseerr.
enum WebPage {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    static func fetch(_ url: URL) async throws -> (html: String, status: Int) {
        var request = URLRequest(url: url)
        request.setValue("Mindseerr/1.0 (Apple TV)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (String(decoding: data, as: UTF8.self), status)
    }
}

enum TextMatch {
    /// All matches of `pattern`; each match gives its first non-empty capture group.
    static func all(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            for group in 1..<max(match.numberOfRanges, 1) {
                if let r = Range(match.range(at: group), in: text), !text[r].isEmpty { return String(text[r]) }
            }
            return nil
        }
    }

    /// The capture groups of the first match of `pattern`.
    static func first(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(match.numberOfRanges, 1)).map { group in
            Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func decodeEntities(_ text: String) -> String {
        var s = text
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#039;", "'"), ("&#39;", "'"),
                               ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        // Remaining numeric entities like &#8217;
        while let groups = first("&#(\\d+);", in: s), let code = UInt32(groups[0]),
              let scalar = Unicode.Scalar(code), let r = s.range(of: "&#\(groups[0]);") {
            s.replaceSubrange(r, with: String(Character(scalar)))
        }
        return s
    }

    /// Splits "Title (1999)" into ("Title", 1999).
    static func splitYear(_ title: String) -> (String, Int?) {
        if let groups = first("^(.*?)\\s*\\((\\d{4})\\)\\s*$", in: title) {
            return (groups[0], Int(groups[1]))
        }
        return (title, nil)
    }
}
