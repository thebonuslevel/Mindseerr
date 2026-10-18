import Foundation

// MARK: - Services

enum ArrKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sonarr, radarr
    /// A download client rather than an *arr app: Mindseerr uses it to pause, resume and read torrents.
    case qbittorrent

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sonarr: return "Sonarr"
        case .radarr: return "Radarr"
        case .qbittorrent: return "qBittorrent"
        }
    }

    /// The port as plain text for addresses. Interpolating the Int into SwiftUI text would format it
    /// like a number ("8,989").
    var defaultPortText: String { String(defaultPort) }

    var defaultPort: Int {
        switch self {
        case .sonarr: return 8989
        case .radarr: return 7878
        case .qbittorrent: return 8080
        }
    }
}

/// A connected Sonarr, Radarr or qBittorrent server.
struct ArrService: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var kind: ArrKind
    var name: String
    var baseURL: URL
    /// The API key: Sonarr and Radarr's, or one created in qBittorrent (5.2 or newer).
    var apiKey: String

    /// Turns what the user typed into a server address: adds http:// when there's no scheme and
    /// drops a trailing slash, keeping any base path (e.g. http://nas:8989/sonarr).
    static func normalizedURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }
}

/// Saved services, kept in the Keychain because each one carries an API key.
enum ArrServiceStore {
    private static let key = "arrServices"

    static func load() -> [ArrService] {
        guard let json = Keychain.get(key),
              let services = try? JSONDecoder().decode([ArrService].self, from: Data(json.utf8)) else { return [] }
        return services
    }

    static func save(_ services: [ArrService]) {
        guard !services.isEmpty, let data = try? JSONEncoder().encode(services) else {
            Keychain.set(nil, for: key)
            return
        }
        Keychain.set(String(decoding: data, as: UTF8.self), for: key)
    }
}

// MARK: - Downloads

/// One item in a Sonarr or Radarr download queue. A Sonarr season pack (many episodes in one
/// download) is combined into a single item.
struct ArrDownload: Identifiable, Sendable {
    enum Phase: Sendable {
        case downloading, queued, paused, importing, delayed, warning, failed, other(String)

        var label: String {
            switch self {
            case .downloading: return "Downloading"
            case .queued: return "Queued"
            case .paused: return "Paused"
            case .importing: return "Importing"
            case .delayed: return "Delayed"
            case .warning: return "Needs attention"
            case .failed: return "Failed"
            case .other(let text): return text.prefix(1).uppercased() + text.dropFirst()
            }
        }

        var isProblem: Bool {
            switch self {
            case .warning, .failed: return true
            default: return false
            }
        }
    }

    let id: String
    let serviceID: UUID
    let serviceName: String
    let kind: ArrKind
    /// The download client's ID for this download: a torrent's info hash. Matches it to a qBittorrent torrent.
    let downloadId: String?
    /// The queue entries behind this download (a season pack has one per episode), for removing it.
    let queueIds: [Int]
    let title: String
    /// "Season 1, Episode 3", "Season 1 · 10 episodes", etc. Nil for movies.
    let episodeLabel: String?
    let tmdbId: Int?
    let tvdbId: Int?
    /// 0...1
    let progress: Double
    let secondsLeft: Int?
    let phase: Phase
    let message: String?
    /// For a download read straight from qBittorrent, what kind of title it turned out to be.
    var resolvedType: MediaType? = nil

    var mediaType: MediaType {
        switch kind {
        case .radarr: return .movie
        case .sonarr: return .tv
        case .qbittorrent: return resolvedType ?? .movie
        }
    }

    var route: MediaRoute? {
        tmdbId.map { MediaRoute(type: mediaType, tmdbId: $0) }
    }

    var timeLeftText: String? {
        guard let secondsLeft, secondsLeft > 0, phase == .downloading else { return nil }
        let minutes = (secondsLeft + 59) / 60
        if minutes < 60 { return "\(minutes) min left" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) h left" : "\(hours) h \(minutes % 60) min left" }
        return "\(hours / 24) d \(hours % 24) h left"
    }

    /// Whether this download is for the given movie or series. Series match on either ID, since
    /// Sonarr v3 only knows the TVDB ID.
    func matches(type: MediaType, tmdbId: Int?, tvdbId: Int?) -> Bool {
        guard type == mediaType else { return false }
        if let id = self.tmdbId, id == tmdbId { return true }
        if let id = self.tvdbId, id == tvdbId { return true }
        return false
    }

    /// Whether this download is for the title a Seerr request is about.
    func matches(_ media: RequestMedia?) -> Bool {
        guard let media, let type = media.mediaType else { return false }
        return matches(type: type, tmdbId: media.tmdbId, tvdbId: media.tvdbId)
    }
}

extension ArrDownload.Phase: Equatable {}

// MARK: - Client

/// Reads Sonarr and Radarr through their v3 API (Sonarr v3/v4, Radarr v3+), signed with the API key.
enum ArrClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Checks the address and key. Returns the server's version, or throws a readable error.
    static func checkConnection(_ service: ArrService) async throws -> String {
        let status: SystemStatus = try await get("system/status", from: service)
        if let app = status.appName, app.lowercased() != service.kind.rawValue {
            throw APIError(status: 0, message: "That address is a \(app) server, not \(service.kind.name).")
        }
        return status.version ?? "unknown version"
    }

    static func downloads(from service: ArrService) async throws -> [ArrDownload] {
        let query: [URLQueryItem] = service.kind == .radarr
            ? [.init(name: "includeMovie", value: "true")]
            : [.init(name: "includeSeries", value: "true"), .init(name: "includeEpisode", value: "true")]
        let page: QueuePage = try await get("queue", from: service, query: query + [
            .init(name: "page", value: "1"),
            .init(name: "pageSize", value: "200"),
        ])

        // Sonarr lists each episode of a season pack separately; group them by their shared download.
        var groups: [String: [QueueRecord]] = [:]
        var order: [String] = []
        for record in page.records {
            let key = record.downloadId ?? "queue-\(record.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(record)
        }
        return order.compactMap { key in
            guard let records = groups[key], let first = records.first else { return nil }
            return makeDownload(key: key, records: records, first: first, service: service)
        }
    }

    private static func makeDownload(key: String, records: [QueueRecord], first: QueueRecord,
                                     service: ArrService) -> ArrDownload {
        let size = first.size ?? 0
        let left = first.sizeleft ?? 0
        let progress = size > 0 ? min(max(1 - left / size, 0), 1) : 0

        let episodeLabel = service.kind == .sonarr ? Self.episodeLabel(for: records) : nil

        let title = first.movie?.title ?? first.series?.title ?? first.title ?? "Unknown title"
        return ArrDownload(
            id: "\(service.id.uuidString)-\(key)",
            serviceID: service.id,
            serviceName: service.name,
            kind: service.kind,
            downloadId: first.downloadId,
            queueIds: records.map(\.id),
            title: title,
            episodeLabel: episodeLabel,
            tmdbId: first.movie?.tmdbId ?? first.series?.tmdbId,
            tvdbId: first.series?.tvdbId,
            progress: progress,
            secondsLeft: first.timeleft.flatMap(parseTimeLeft),
            phase: phase(of: first),
            message: first.errorMessage ?? first.statusMessages?.first?.messages?.first
        )
    }

    /// Which season (and episode, for a single one) a Sonarr download covers:
    /// "Season 1, Episode 3", "Season 1 · 10 episodes", "Seasons 1–3 · 24 episodes".
    /// Falls back to the record's own season number when Sonarr leaves out the episode details.
    private static func episodeLabel(for records: [QueueRecord]) -> String? {
        let episodes = records.compactMap(\.episode)
        if episodes.count == 1, let episode = episodes.first {
            return "Season \(episode.seasonNumber), Episode \(episode.episodeNumber)"
        }
        let seasons = Set(episodes.isEmpty ? records.compactMap(\.seasonNumber) : episodes.map(\.seasonNumber)).sorted()
        guard let firstSeason = seasons.first, let lastSeason = seasons.last else { return nil }

        let seasonText: String
        if seasons.count == 1 {
            seasonText = "Season \(firstSeason)"
        } else if lastSeason - firstSeason + 1 == seasons.count {
            seasonText = "Seasons \(firstSeason)–\(lastSeason)"
        } else {
            seasonText = "Seasons " + seasons.map(String.init).joined(separator: ", ")
        }
        return episodes.count > 1 ? "\(seasonText) · \(episodes.count) episodes" : seasonText
    }

    private static func phase(of record: QueueRecord) -> ArrDownload.Phase {
        let state = record.trackedDownloadState?.lowercased() ?? ""
        if state.hasPrefix("import") { return .importing }
        if state == "failedpending" || state == "failed" { return .failed }
        if record.trackedDownloadStatus?.lowercased() == "warning" { return .warning }
        switch record.status?.lowercased() ?? "" {
        case "downloading": return .downloading
        case "queued": return .queued
        case "paused": return .paused
        case "delay": return .delayed
        case "completed": return .importing
        case "warning": return .warning
        case "failed": return .failed
        case let other: return .other(other.isEmpty ? "Unknown" : other)
        }
    }

    /// Arr reports time left as "HH:MM:SS" or "D.HH:MM:SS".
    static func parseTimeLeft(_ text: String) -> Int? {
        var days = 0
        var clock = Substring(text)
        if let dot = clock.firstIndex(of: "."), clock[..<dot].allSatisfy(\.isNumber) {
            days = Int(clock[..<dot]) ?? 0
            clock = clock[clock.index(after: dot)...]
        }
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return ((days * 24 + parts[0]) * 60 + parts[1]) * 60 + parts[2]
    }

    // MARK: Plumbing

    /// Takes a download out of the queue and deletes it from the download client too, without
    /// blocklisting the release. The Seerr request is left alone.
    static func cancel(_ download: ArrDownload, on service: ArrService) async throws {
        struct Body: Encodable { let ids: [Int] }
        _ = try await send("queue/bulk", method: "DELETE", from: service, query: [
            .init(name: "removeFromClient", value: "true"),
            .init(name: "blocklist", value: "false"),
        ], body: try JSONEncoder().encode(Body(ids: download.queueIds)))
    }

    private static func get<T: Decodable>(_ path: String, from service: ArrService,
                                          query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path, method: "GET", from: service, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError(status: 0, message: "\(service.name) sent a response the app didn't understand. Is that a \(service.kind.name) server?")
        }
    }

    private static func send(_ path: String, method: String, from service: ArrService,
                             query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var url = service.baseURL.appendingPathComponent("api/v3").appendingPathComponent(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(service.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw APIError(status: 0, message: "Couldn't reach \(service.name) at \(service.baseURL.absoluteString). Check the address and port.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw APIError(status: status, message: "\(service.name) rejected the API key. Copy it again from Settings → General in \(service.kind.name).")
        case 404: throw APIError(status: status, message: "\(service.name) didn't recognize that address. If it uses a URL base (like /\(service.kind.rawValue)), include it.")
        default: throw APIError(status: status, message: "\(service.name) returned error \(status).")
        }
    }

    // MARK: Wire types

    private struct SystemStatus: Decodable {
        let appName: String?
        let version: String?
    }

    private struct QueuePage: Decodable {
        let records: [QueueRecord]
    }

    private struct QueueRecord: Decodable {
        struct Movie: Decodable { let title: String?; let tmdbId: Int? }
        struct Series: Decodable { let title: String?; let tvdbId: Int?; let tmdbId: Int? }
        struct Episode: Decodable { let seasonNumber: Int; let episodeNumber: Int }
        struct StatusMessage: Decodable { let messages: [String]? }

        let id: Int
        let title: String?
        let size: Double?
        let sizeleft: Double?
        let timeleft: String?
        let status: String?
        let trackedDownloadStatus: String?
        let trackedDownloadState: String?
        let errorMessage: String?
        let statusMessages: [StatusMessage]?
        let downloadId: String?
        let seasonNumber: Int?
        let movie: Movie?
        let series: Series?
        let episode: Episode?
    }
}
