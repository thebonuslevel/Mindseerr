import Foundation

/// Which sections of Discover are shown, chosen under Settings → Discover Sections. Everything is on by default; the
/// ones switched off are remembered (so a section added later starts on).
enum DiscoverLayout {
    static let storageKey = "discover.hiddenSections"

    /// Everything Discover can show, in order: the personalised row first, then Seerr's sections.
    enum Entry: String, CaseIterable, Identifiable {
        case suggested, recentlyAdded, trending, popularMovies, upcomingMovies, popularTV, upcomingTV

        var id: String { rawValue }

        var title: String {
            switch self {
            case .suggested: return "Suggested for You"
            case .recentlyAdded: return DiscoverSection.recentlyAdded.title
            case .trending: return DiscoverSection.trending.title
            case .popularMovies: return DiscoverSection.popularMovies.title
            case .upcomingMovies: return DiscoverSection.upcomingMovies.title
            case .popularTV: return DiscoverSection.popularTV.title
            case .upcomingTV: return DiscoverSection.upcomingTV.title
            }
        }
    }

    /// The hidden sections' ids, stored as one comma-separated string so `@AppStorage` can watch it.
    static func hidden(_ stored: String) -> Set<String> {
        Set(stored.split(separator: ",").map(String.init))
    }

    static func store(_ hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: ",")
    }
}
