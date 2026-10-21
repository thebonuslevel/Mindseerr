import Foundation

/// A way into Seerr's discovery beyond the fixed rows: pick a genre, studio or network, then see its titles.
enum BrowseKind: String, Hashable, CaseIterable, Identifiable, Sendable {
    case movieGenres, tvGenres, studios, networks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movieGenres: return "Movie Genres"
        case .tvGenres: return "Series Genres"
        case .studios: return "Studios"
        case .networks: return "Networks"
        }
    }

    var symbol: String {
        switch self {
        case .movieGenres: return "film"
        case .tvGenres: return "tv"
        case .studios: return "building.2"
        case .networks: return "antenna.radiowaves.left.and.right"
        }
    }

    var mediaType: MediaType { self == .movieGenres || self == .studios ? .movie : .tv }
}

/// One genre, studio or network to list titles for.
struct BrowseTarget: Hashable, Sendable {
    enum Filter: String, Hashable, Sendable { case genre, studio, network }

    let type: MediaType
    let filter: Filter
    let id: Int
    let name: String

    /// The heading above its titles: "Comedy Movies", "Netflix Series", "Pixar Movies".
    var heading: String {
        switch filter {
        case .genre: return "\(name) \(type == .tv ? "Series" : "Movies")"
        case .studio: return "\(name) Movies"
        case .network: return "\(name) Series"
        }
    }
}

/// The order a browsed list comes in.
enum BrowseSort: String, CaseIterable, Sendable {
    case popular, topRated, newest

    var title: String {
        switch self {
        case .popular: return "Most Popular"
        case .topRated: return "Top Rated"
        case .newest: return "Newest"
        }
    }

    var next: BrowseSort {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// TMDB's sort key, which differs between movies and series for dates.
    func sortBy(for type: MediaType) -> String {
        switch self {
        case .popular: return "popularity.desc"
        case .topRated: return "vote_average.desc"
        case .newest: return type == .tv ? "first_air_date.desc" : "primary_release_date.desc"
        }
    }
}

/// Well-known studios and networks, by their TMDB ids. Seerr has no list of them to ask for, only titles by id.
enum KnownCompanies {
    /// Logos shipped in the app, by studio id, where TMDB's own doesn't whiten cleanly.
    static let bundledLogos: [Int: String] = [420: "MarvelStudiosLogo"]

    static let studios: [(id: Int, name: String)] = [
        (2, "Disney"), (3, "Pixar"), (420, "Marvel Studios"), (9993, "DC Entertainment"), (174, "Warner Bros."),
        (33, "Universal"), (4, "Paramount"), (5, "Columbia"), (25, "20th Century"), (21, "MGM"),
        (1632, "Lionsgate"), (41077, "A24"), (521, "DreamWorks"), (923, "Legendary"), (3172, "Blumhouse"),
        (10342, "Studio Ghibli"),
    ]

    static let networks: [(id: Int, name: String)] = [
        (213, "Netflix"), (49, "HBO"), (2739, "Disney+"), (2552, "Apple TV+"), (1024, "Prime Video"),
        (453, "Hulu"), (4330, "Paramount+"), (3353, "Peacock"), (174, "AMC"), (88, "FX"),
        (67, "Showtime"), (4, "BBC One"), (56, "Cartoon Network"), (80, "Adult Swim"),
    ]
}
