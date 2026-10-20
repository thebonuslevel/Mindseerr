import Foundation

/// Status of a request itself (as opposed to the media's availability).
enum RequestStatus: Int, Decodable, Sendable {
    case unknown = 0
    case pendingApproval = 1
    case approved = 2
    case declined = 3
    case failed = 4
    case completed = 5

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = RequestStatus(rawValue: raw) ?? .unknown
    }
}

struct MediaRequest: Decodable, Identifiable, Sendable {
    let id: Int
    let status: RequestStatus
    let is4k: Bool?
    let createdAt: String?
    let media: RequestMedia?
    let seasons: [RequestSeason]?
    let requestedBy: SeerrUser?

    var route: MediaRoute? {
        guard let media, let tmdbId = media.tmdbId, let type = media.mediaType,
              type == .movie || type == .tv else { return nil }
        return MediaRoute(type: type, tmdbId: tmdbId)
    }

    /// The title's availability, for a second badge next to the request's own status. Nil when it would
    /// just repeat it ("Pending Approval" next to "Pending").
    var secondaryMediaStatus: MediaStatus? {
        guard let status = media?.status else { return nil }
        if status == .pending && self.status == .pendingApproval { return nil }
        return status
    }

    /// Done: the request is marked completed, or its title is fully available on the server.
    var isCompleted: Bool {
        status == .completed || media?.status == .available
    }

    var createdDateText: String? {
        guard let createdAt else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = precise.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
        return date?.formatted(date: .abbreviated, time: .omitted)
    }
}

struct RequestMedia: Decodable, Sendable {
    let id: Int
    let tmdbId: Int?
    /// Sonarr identifies series by TVDB ID; used to match its downloads to requests.
    let tvdbId: Int?
    let mediaType: MediaType?
    let status: MediaStatus?
    /// What Seerr itself sees Sonarr or Radarr downloading for this title, for every user (standard and 4K copies).
    let downloadStatus: [SeerrDownloadItem]?
    let downloadStatus4k: [SeerrDownloadItem]?
}

/// One download as Seerr reports it on a title. Every field is optional and read leniently, so an oddly shaped
/// entry from a different Seerr version can't stop a request from loading.
struct SeerrDownloadItem: Decodable, Sendable {
    let externalId: Int?
    let title: String?
    /// Sonarr's or Radarr's queue status: "downloading", "paused", "queued", "completed"...
    let status: String?
    let size: Double?
    let sizeLeft: Double?
    /// "HH:MM:SS".
    let timeLeft: String?
    let seasonNumber: Int?
    let episodeNumber: Int?

    private enum Keys: String, CodingKey { case externalId, title, status, size, sizeLeft, timeLeft, episode }
    private enum EpisodeKeys: String, CodingKey { case seasonNumber, episodeNumber }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        externalId = try? c.decodeIfPresent(Int.self, forKey: .externalId)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        size = try? c.decodeIfPresent(Double.self, forKey: .size)
        sizeLeft = try? c.decodeIfPresent(Double.self, forKey: .sizeLeft)
        timeLeft = try? c.decodeIfPresent(String.self, forKey: .timeLeft)
        let episode = try? c.nestedContainer(keyedBy: EpisodeKeys.self, forKey: .episode)
        seasonNumber = (try? episode?.decodeIfPresent(Int.self, forKey: .seasonNumber)) ?? nil
        episodeNumber = (try? episode?.decodeIfPresent(Int.self, forKey: .episodeNumber)) ?? nil
    }
}

struct RequestSeason: Decodable, Sendable {
    let id: Int?
    let seasonNumber: Int
    let status: RequestStatus?
}

struct RequestPage: Decodable, Sendable {
    struct PageInfo: Decodable, Sendable {
        let pages: Int
        let pageSize: Int?
        let results: Int
        let page: Int
    }
    let pageInfo: PageInfo
    let results: [MediaRequest]
}
