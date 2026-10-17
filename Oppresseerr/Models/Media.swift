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
}

struct SeasonAvailability: Decodable, Sendable {
    let seasonNumber: Int
    let status: MediaStatus
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
    }

    static func url(_ path: String?, size: Size) -> URL? {
        guard let path, !path.isEmpty else { return nil }
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

// MARK: - Movie / series detail

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

    var displayTitle: String { title ?? name ?? "Untitled" }
    var year: String? { yearString(releaseDate ?? firstAirDate) }

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
        case .available: return "Available"
        case .partiallyAvailable: return "Partially Available"
        case .requested: return "Requested"
        case .notRequested: return nil
        }
    }
}

extension MediaDetail {
    /// Seasons excluding specials (season 0), in order.
    var regularSeasons: [Season] {
        (seasons ?? []).filter { $0.seasonNumber > 0 }.sorted { $0.seasonNumber < $1.seasonNumber }
    }

    func state(ofSeason number: Int) -> SeasonState {
        if let status = mediaInfo?.seasons?.first(where: { $0.seasonNumber == number })?.status {
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
                && request.is4k != true
                && (request.seasons ?? []).contains { $0.seasonNumber == number }
        }
        return activeRequest ? .requested : .notRequested
    }

    var requestableSeasonNumbers: [Int] {
        regularSeasons.map(\.seasonNumber).filter { state(ofSeason: $0) == .notRequested }
    }
}

enum RequestAvailability {
    case requestable, partiallyRequestable, requested, available

    init(detail: MediaDetail, type: MediaType) {
        let status = detail.mediaInfo?.status ?? .unknown

        if type == .movie {
            switch status {
            case .available, .partiallyAvailable: self = .available
            case .pending, .processing: self = .requested
            default: self = .requestable
            }
            return
        }

        let all = detail.regularSeasons.map(\.seasonNumber)
        let open = detail.requestableSeasonNumbers

        if status == .available {
            self = .available
        } else if all.isEmpty {
            self = (status == .unknown || status == .deleted) ? .requestable : .requested
        } else if open.count == all.count {
            self = .requestable
        } else if !open.isEmpty {
            self = .partiallyRequestable
        } else if all.allSatisfy({ detail.state(ofSeason: $0) == .available }) {
            self = .available
        } else {
            self = .requested
        }
    }
}
