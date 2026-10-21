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

    /// What the Top Shelf can show: any Discover section, or the suggestions row. The raw values match
    /// the app's `DiscoverSection`, so a Discover row saves under its own id.
    enum Section: String, CaseIterable, Identifiable {
        case suggested, recentlyAdded, trending, popularMovies, upcomingMovies, popularTV, upcomingTV

        var id: String { rawValue }

        var title: String {
            switch self {
            case .suggested: return String(localized: "Suggested for You")
            case .recentlyAdded: return String(localized: "Recently Added")
            case .trending: return String(localized: "Trending")
            case .popularMovies: return String(localized: "Popular Movies")
            case .upcomingMovies: return String(localized: "Upcoming Movies")
            case .popularTV: return String(localized: "Popular Series")
            case .upcomingTV: return String(localized: "Upcoming Series")
            }
        }

        /// The heading above the posters on the Top Shelf.
        var shelfTitle: String { self == .trending ? "Trending on Seerr" : title }
    }

    private static let sectionKey = "topShelf.section"

    /// Which section the Top Shelf shows (Trending by default). Stored in the App Group so the extension can read it.
    static var section: Section {
        get { Section(rawValue: defaults?.string(forKey: sectionKey) ?? "") ?? .trending }
        set { defaults?.set(newValue.rawValue, forKey: sectionKey) }
    }

    /// Kept in the App Group's shared defaults, not a file: tvOS only lets apps write files to Caches,
    /// so a file in the group container works in the Simulator but fails on a real Apple TV.
    private static func itemsKey(_ section: Section) -> String { "topShelf.items.\(section.rawValue)" }
    /// Where the first version kept the trending titles.
    private static let legacyTrendingKey = "topShelf.trending"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func save(_ items: [Item], for section: Section = .trending) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults?.set(data, forKey: itemsKey(section))
    }

    static func load(_ section: Section = .trending) -> [Item] {
        let data = defaults?.data(forKey: itemsKey(section))
            ?? (section == .trending ? defaults?.data(forKey: legacyTrendingKey) : nil)
        guard let data else { return [] }
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
