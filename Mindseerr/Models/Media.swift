import Foundation

// MARK: - Enums

enum MediaType: String, Codable, Hashable, Sendable {
    case movie, tv, person, collection, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MediaType(rawValue: raw) ?? .unknown
    }
}

/// Availability of a title on the media server, as tracked by Seerr.
enum MediaStatus: Int, Codable, Sendable {
    case unknown = 1
    case pending = 2
    case processing = 3
    case partiallyAvailable = 4
    case available = 5
    case deleted = 6

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = MediaStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - Shared pieces

struct MediaRoute: Hashable, Sendable {
    let type: MediaType
    let tmdbId: Int
}

struct MediaInfo: Decodable, Sendable {
    let id: Int?
    let tmdbId: Int?
    /// Used to match Sonarr downloads, which may only know a series by its TVDB ID.
    let tvdbId: Int?
    let status: MediaStatus?
    let status4k: MediaStatus?
    let seasons: [SeasonAvailability]?
    let requests: [MediaRequest]?
    /// Where the title lives on the media server, for the built-in player: Plex's item key, Jellyfin and Emby's item ID,
    /// and the links Seerr keeps to it (which also give the server's address).
    let ratingKey: String?
    let jellyfinMediaId: String?
    let mediaUrl: String?
    let plexUrl: String?
}

struct SeasonAvailability: Decodable, Sendable {
    let seasonNumber: Int
    let status: MediaStatus
    /// Seerr tracks the 4K copy separately.
    let status4k: MediaStatus?
}

struct PagedResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let page: Int
    let totalPages: Int
    let totalResults: Int
    let results: [T]
}

enum TMDBImage {
    enum Size: String {
        case poster = "w342"
        case posterLarge = "w500"
        case backdrop = "w1280"
        case profile = "w185"
        case logo = "w300"
    }

    static func url(_ path: String?, size: Size) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        #if DEBUG
        if let base = DemoMode.imageBase { return URL(string: base + path) }
        #endif
        return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)\(path)")
    }
}

private func yearString(_ date: String?) -> String? {
    guard let date, date.count >= 4 else { return nil }
    return String(date.prefix(4))
}

// MARK: - Discover / search result

struct MediaResult: Decodable, Sendable {
    let id: Int
    private let mediaType: MediaType?
    let title: String?
    let name: String?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let mediaInfo: MediaInfo?

    var type: MediaType { mediaType ?? (title != nil ? .movie : .tv) }
    var uid: String { "\(type.rawValue)-\(id)" }
    var displayTitle: String { title ?? name ?? "Untitled" }
    var year: String? { yearString(releaseDate ?? firstAirDate) }
    var posterURL: URL? { TMDBImage.url(posterPath, size: .poster) }

    /// Only movies and series can be opened and requested.
    var route: MediaRoute? {
        (type == .movie || type == .tv) ? MediaRoute(type: type, tmdbId: id) : nil
    }
}

// MARK: - Episodes

/// A season with its episodes (`/tv/{id}/season/{n}`).
struct SeasonDetail: Decodable, Sendable {
    let seasonNumber: Int?
    let name: String?
    let episodes: [Episode]?
}

struct Episode: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String?
    let overview: String?
    let episodeNumber: Int
    let seasonNumber: Int
    let runtime: Int?
}

// MARK: - People

/// A cast or crew member, as a place to navigate to.
struct PersonRoute: Hashable, Sendable {
    let id: Int
    let name: String
    let profilePath: String?
}

/// A person's details (`/person/{id}`).
struct PersonDetail: Decodable, Sendable {
    let id: Int
    let name: String
    let biography: String?
    let birthday: String?
    let placeOfBirth: String?
    let profilePath: String?
    let knownForDepartment: String?
}

/// Everything a person has been in (`/person/{id}/combined_credits`), as titles. A title can appear in both
/// lists when the person acted in and directed it.
struct PersonCredits: Decodable, Sendable {
    let cast: [MediaResult]?
    let crew: [MediaResult]?
}

// MARK: - Rotten Tomatoes

/// Rotten Tomatoes scores for a title, as Seerr passes them along (`/movie/{id}/ratings`, `/tv/{id}/ratings`).
/// Series only carry the critics' score.
struct RottenTomatoesRating: Decodable, Sendable {
    let criticsScore: Int?
    /// "Certified Fresh", "Fresh" or "Rotten".
    let criticsRating: String?
    let audienceScore: Int?
    /// "Upright" or "Spilled".
    let audienceRating: String?

    var hasScore: Bool { criticsScore != nil || audienceScore != nil }
}

extension MediaResult {
    /// A result built from a title's details, for lists Seerr only gives as bare ids (like Recently Added).
    static func make(from detail: MediaDetail, route: MediaRoute) -> MediaResult? {
        var json: [String: Any] = ["id": route.tmdbId, "mediaType": route.type.rawValue]
        json[route.type == .tv ? "name" : "title"] = detail.displayTitle
        json["posterPath"] = detail.posterPath
        json["backdropPath"] = detail.backdropPath
        json["overview"] = detail.overview
        json[route.type == .tv ? "firstAirDate" : "releaseDate"] = detail.releaseDate ?? detail.firstAirDate
        json["voteAverage"] = detail.voteAverage
        // The details say how available it is, so the poster gets the same badge as elsewhere.
        json["mediaInfo"] = ["status": detail.mediaInfo?.status?.rawValue ?? MediaStatus.available.rawValue]
        let clean = json.compactMapValues { $0 is NSNull ? nil : $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: clean) else { return nil }
        return try? JSONDecoder().decode(MediaResult.self, from: data)
    }
}

// MARK: - Movie / series detail

/// Cast and crew as TMDB lists them, passed along by Seerr.
struct Credits: Decodable, Sendable {
    let cast: [CastMember]?
    let crew: [CrewMember]?
}

struct CastMember: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?
    let order: Int?
}

struct CrewMember: Decodable, Sendable {
    let id: Int
    let name: String
    let job: String?
    let department: String?
    let profilePath: String?
}

struct Creator: Decodable, Sendable {
    let id: Int
    let name: String
    let profilePath: String?
}

/// One person in the Crew row, with every notable job they had on the title.
struct CrewCredit: Identifiable, Sendable {
    let id: Int
    let name: String
    let jobs: [String]
    let profilePath: String?
}

/// A video TMDB lists for a title (trailers, teasers, clips), as Seerr passes it along.
struct RelatedVideo: Decodable, Sendable {
    let key: String?
    let name: String?
    let type: String?
    let site: String?

    /// Opens the video in the YouTube app on Apple TV, which can't play YouTube inside other apps.
    var youTubeAppURL: URL? {
        key.flatMap { URL(string: "youtube://www.youtube.com/watch?v=\($0)") }
    }
}

struct Genre: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
}

struct Season: Decodable, Identifiable, Sendable {
    let id: Int
    let seasonNumber: Int
    let name: String?
    let episodeCount: Int?
    let airDate: String?
}

/// One type for both `/movie/{id}` and `/tv/{id}`; fields that only exist on one are optional.
struct MediaDetail: Decodable, Sendable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let tagline: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let runtime: Int?
    let voteAverage: Double?
    let genres: [Genre]?
    let seasons: [Season]?
    let numberOfSeasons: Int?
    let mediaInfo: MediaInfo?
    let relatedVideos: [RelatedVideo]?
    let credits: Credits?
    /// Series creators (TV only).
    let createdBy: [Creator]?

    var displayTitle: String { title ?? name ?? "Untitled" }
    var year: String? { yearString(releaseDate ?? firstAirDate) }

    /// Billed cast, in order.
    var cast: [CastMember] {
        (credits?.cast ?? []).sorted { ($0.order ?? .max) < ($1.order ?? .max) }
    }

    /// Key crew (creators, directors, writers, producers, composer, cinematographer), one entry per person.
    var keyCrew: [CrewCredit] {
        let ranked = ["Creator", "Director", "Screenplay", "Writer", "Story", "Novel", "Producer",
                      "Executive Producer", "Original Music Composer", "Director of Photography"]
        var order: [Int] = []
        var byPerson: [Int: (name: String, jobs: [String], photo: String?)] = [:]
        func add(_ id: Int, _ name: String, _ job: String, _ photo: String?) {
            guard ranked.contains(job) else { return }
            if byPerson[id] == nil { order.append(id); byPerson[id] = (name, [], photo) }
            if !(byPerson[id]!.jobs.contains(job)) { byPerson[id]!.jobs.append(job) }
        }
        for c in createdBy ?? [] { add(c.id, c.name, "Creator", c.profilePath) }
        for c in credits?.crew ?? [] { if let job = c.job { add(c.id, c.name, job, c.profilePath) } }
        func rank(_ id: Int) -> Int { byPerson[id]!.jobs.compactMap { ranked.firstIndex(of: $0) }.min() ?? ranked.count }
        return order.sorted { rank($0) < rank($1) }.prefix(16).map { id in
            let p = byPerson[id]!
            return CrewCredit(id: id, name: p.name, jobs: p.jobs.sorted { (ranked.firstIndex(of: $0) ?? 99) < (ranked.firstIndex(of: $1) ?? 99) },
                              profilePath: p.photo)
        }
    }

    /// The YouTube trailer to offer, falling back to a teaser when there's no trailer.
    var trailer: RelatedVideo? {
        let youtube = (relatedVideos ?? []).filter { $0.site?.lowercased() == "youtube" && $0.key?.isEmpty == false }
        return youtube.first { $0.type == "Trailer" } ?? youtube.first { $0.type == "Teaser" }
    }

    var metadataLine: String {
        var parts: [String] = []
        if let year { parts.append(year) }
        if let runtime, runtime > 0 {
            parts.append(runtime >= 60 ? "\(runtime / 60)h \(runtime % 60)m" : "\(runtime)m")
        } else if let n = numberOfSeasons, n > 0 {
            parts.append(n == 1 ? "1 Season" : "\(n) Seasons")
        }
        if let genres, !genres.isEmpty {
            parts.append(genres.prefix(3).map(\.name).joined(separator: ", "))
        }
        if let voteAverage, voteAverage > 0 {
            parts.append(String(format: "★ %.1f", voteAverage))
        }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Season & request state

enum SeasonState {
    case available, partiallyAvailable, requested, notRequested

    var label: String? {
        switch self {
        case .available: return String(localized: "Available")
        case .partiallyAvailable: return String(localized: "Partially Available")
        case .requested: return String(localized: "Requested")
        case .notRequested: return nil
        }
    }
}

extension MediaDetail {
    /// Seasons excluding specials (season 0), in order.
    var regularSeasons: [Season] {
        (seasons ?? []).filter { $0.seasonNumber > 0 }.sorted { $0.seasonNumber < $1.seasonNumber }
    }

    /// A season's state for the standard copy, or the separate 4K copy.
    func state(ofSeason number: Int, is4k: Bool = false) -> SeasonState {
        let season = mediaInfo?.seasons?.first(where: { $0.seasonNumber == number })
        if let status = is4k ? season?.status4k : season?.status {
            switch status {
            case .available: return .available
            case .partiallyAvailable: return .partiallyAvailable
            case .pending, .processing: return .requested
            default: break
            }
        }
        let activeRequest = (mediaInfo?.requests ?? []).contains { request in
            request.status != .declined
                && request.status != .failed
                && (request.is4k == true) == is4k
                && (request.seasons ?? []).contains { $0.seasonNumber == number }
        }
        return activeRequest ? .requested : .notRequested
    }

    var requestableSeasonNumbers: [Int] { requestableSeasonNumbers(is4k: false) }

    func requestableSeasonNumbers(is4k: Bool) -> [Int] {
        regularSeasons.map(\.seasonNumber).filter { state(ofSeason: $0, is4k: is4k) == .notRequested }
    }
}

enum RequestAvailability {
    case requestable, partiallyRequestable, requested, available

    /// Availability of the standard copy, or the separate 4K copy.
    init(detail: MediaDetail, type: MediaType, is4k: Bool = false) {
        let status = (is4k ? detail.mediaInfo?.status4k : detail.mediaInfo?.status) ?? .unknown

        if type == .movie {
            switch status {
            case .available, .partiallyAvailable: self = .available
            case .pending, .processing: self = .requested
            default: self = .requestable
            }
            return
        }

        let all = detail.regularSeasons.map(\.seasonNumber)
        let open = detail.requestableSeasonNumbers(is4k: is4k)

        if status == .available {
            self = .available
        } else if all.isEmpty {
            self = (status == .unknown || status == .deleted) ? .requestable : .requested
        } else if open.count == all.count {
            self = .requestable
        } else if !open.isEmpty {
            self = .partiallyRequestable
        } else if all.allSatisfy({ detail.state(ofSeason: $0, is4k: is4k) == .available }) {
            self = .available
        } else {
            self = .requested
        }
    }
}
