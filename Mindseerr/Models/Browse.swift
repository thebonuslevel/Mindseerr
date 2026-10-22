import Foundation

/// A way into Seerr's discovery beyond the fixed rows: pick a genre, studio or network, then see its titles.
enum BrowseKind: String, Hashable, CaseIterable, Identifiable, Sendable {
    case movieGenres, tvGenres, studios, networks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movieGenres: return String(localized: "Movie Genres")
        case .tvGenres: return String(localized: "Series Genres")
        case .studios: return String(localized: "Studios")
        case .networks: return String(localized: "Networks")
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
        case .genre: return type == .tv ? String(localized: "\(name) Series") : String(localized: "\(name) Movies")
        case .studio: return String(localized: "\(name) Movies")
        case .network: return String(localized: "\(name) Series")
        }
    }
}

/// The order a browsed list comes in.
enum BrowseSort: String, CaseIterable, Sendable {
    case popular, topRated, newest

    var title: String {
        switch self {
        case .popular: return String(localized: "Most Popular")
        case .topRated: return String(localized: "Top Rated")
        case .newest: return String(localized: "Newest")
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
    /// Studios whose logo from Seerr is a coloured box with lettering in it (Marvel's red box), which would come out
    /// as a plain white block if every pixel were whitened. The box is cut away instead (see `LogoMask`).
    static let boxedLogos: Set<Int> = [420]

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

/// How a genre's card looks: Seerr's own duotone pair for the genre, applied to one of its backdrops by TMDB's image
/// service (the same way Seerr's website does it).
enum GenreStyle {
    private static let tones: [String: (dark: String, light: String)] = [
        "red": ("991B1B", "FCA5A5"), "darkred": ("1F2937", "F87171"), "blue": ("032541", "01B4E4"),
        "lightblue": ("1F2937", "60A5FA"), "darkblue": ("1F2937", "2864D2"), "orange": ("92400E", "FCD34D"),
        "lightgreen": ("065F46", "6EE7B7"), "green": ("087D29", "21CB51"), "purple": ("5B21B6", "C4B5FD"),
        "yellow": ("777E0D", "E4ED55"), "darkorange": ("552C01", "D47C1D"), "black": ("1F2937", "D1D5DB"),
        "pink": ("9D174D", "F9A8D4"), "darkpurple": ("480C8B", "A96BEF"),
    ]

    /// TMDB genre id to tone, as on Seerr's website.
    private static let byGenre: [Int: String] = [
        28: "red", 12: "darkpurple", 16: "blue", 35: "orange", 80: "darkblue", 99: "lightgreen", 18: "pink",
        10751: "yellow", 14: "lightblue", 36: "orange", 27: "black", 10402: "blue", 9648: "purple", 10749: "pink",
        878: "lightblue", 10770: "red", 53: "black", 10752: "darkred", 37: "orange", 10759: "darkpurple",
        10762: "blue", 10763: "black", 10764: "darkorange", 10765: "lightblue", 10766: "pink", 10767: "lightgreen",
        10768: "darkred",
    ]

    static func tone(for genreID: Int) -> (dark: String, light: String) {
        tones[byGenre[genreID] ?? "black"] ?? ("1F2937", "D1D5DB")
    }

    /// Seerr shows the fifth backdrop; fall back to the last one there is.
    static func backdrop(from paths: [String]?) -> String? {
        guard let paths, !paths.isEmpty else { return nil }
        return paths.count > 4 ? paths[4] : paths.last
    }

    static func imageURL(path: String, genreID: Int) -> URL? {
        let tone = tone(for: genreID)
        return URL(string: "https://image.tmdb.org/t/p/w780_filter(duotone,\(tone.dark),\(tone.light))\(path)")
    }
}
