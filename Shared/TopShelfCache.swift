import Foundation

/// Trending titles saved by the app for the Top Shelf extension, in the App Group both can read.
/// The extension has no server address or sign-in of its own, so it shows whatever the app saved last.
enum TopShelfCache {
    static let appGroup = "group.com.example.mindseerr"
    static let urlScheme = "mindseerr"

    struct Item: Codable, Sendable {
        /// "movie" or "tv"
        let type: String
        let tmdbId: Int
        let title: String
        let posterURL: URL?
    }

    private static let enabledKey = "topShelf.enabled"

    /// Whether the Top Shelf shows trending titles (on by default). When off, the extension shows nothing
    /// and tvOS falls back to the static banner. Stored in the App Group so the extension can read it.
    static var isEnabled: Bool {
        get { defaults?.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    /// Kept in the App Group's shared defaults, not a file: tvOS only lets apps write files to Caches,
    /// so a file in the group container works in the Simulator but fails on a real Apple TV.
    private static let itemsKey = "topShelf.trending"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func save(_ items: [Item]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults?.set(data, forKey: itemsKey)
    }

    static func load() -> [Item] {
        guard let data = defaults?.data(forKey: itemsKey) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    /// `mindseerr://media/movie/123` opens that title in the app.
    static func link(type: String, tmdbId: Int) -> URL? {
        URL(string: "\(urlScheme)://media/\(type)/\(tmdbId)")
    }

    /// The (type, tmdbId) in a link made by `link(type:tmdbId:)`.
    static func parse(_ url: URL) -> (type: String, tmdbId: Int)? {
        guard url.scheme == urlScheme, url.host == "media" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let id = Int(parts[1]), ["movie", "tv"].contains(parts[0]) else { return nil }
        return (parts[0], id)
    }
}
