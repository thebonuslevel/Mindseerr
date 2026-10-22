import Foundation
import CryptoKit

/// Keeps what Browse needs to show studio and network logos, so they appear straight away and still do when Seerr or
/// TMDB can't be reached: which logo each company has (asked of Seerr once, then remembered), and the logo images
/// themselves (saved in the app's cache folder after the first download).
enum LogoCache {
    private static let pathsKey = "browse.logoPaths"
    private static let lock = NSLock()

    private static func key(for target: BrowseTarget) -> String {
        "\(target.filter == .network ? "network" : "studio"):\(target.id)"
    }

    /// The logo path Seerr gave for this company earlier, if it did.
    static func path(for target: BrowseTarget) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: pathsKey) as? [String: String])?[key(for: target)]
    }

    static func save(_ path: String, for target: BrowseTarget) {
        lock.lock(); defer { lock.unlock() }
        var all = UserDefaults.standard.dictionary(forKey: pathsKey) as? [String: String] ?? [:]
        all[key(for: target)] = path
        UserDefaults.standard.set(all, forKey: pathsKey)
    }

    // MARK: - Images

    private static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BrowseLogos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func file(for url: URL) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name)
    }

    /// The image's bytes: from the cache folder if it's been downloaded before, otherwise downloaded now and kept.
    /// With `maxAge`, a saved copy older than that is downloaded again (and the old one is used if that fails).
    static func imageData(for url: URL, maxAge: TimeInterval? = nil) async -> Data? {
        let cached = file(for: url)
        let saved = try? Data(contentsOf: cached)
        if let saved, !saved.isEmpty {
            let saveDate = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if maxAge == nil || saveDate.map({ Date().timeIntervalSince($0) < maxAge! }) == true { return saved }
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            return saved.flatMap { $0.isEmpty ? nil : $0 }
        }
        try? data.write(to: cached, options: .atomic)
        return data
    }
}

/// The genres Seerr lists for movies or series, with the backdrop each card uses, kept for a week. Seerr picks the
/// backdrops afresh on every request, so without this the cards would change each visit.
enum GenreCache {
    static let maxAge: TimeInterval = 7 * 24 * 3600

    struct Entry: Codable, Sendable {
        let id: Int
        let name: String
        let backdrop: String?
    }

    private struct Stored: Codable {
        let saved: Date
        let genres: [Entry]
    }

    private static func key(_ type: MediaType) -> String { "browse.genres.\(type.rawValue)" }

    /// The saved list and whether it's still fresh. A stale one is still worth showing when Seerr can't be reached.
    static func load(_ type: MediaType) -> (genres: [Entry], fresh: Bool)? {
        guard let data = UserDefaults.standard.data(forKey: key(type)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), !stored.genres.isEmpty else { return nil }
        return (stored.genres, Date().timeIntervalSince(stored.saved) < maxAge)
    }

    static func save(_ genres: [Entry], for type: MediaType) {
        guard !genres.isEmpty, let data = try? JSONEncoder().encode(Stored(saved: Date(), genres: genres)) else { return }
        UserDefaults.standard.set(data, forKey: key(type))
    }
}
