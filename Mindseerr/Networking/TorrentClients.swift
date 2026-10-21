import Foundation

/// One torrent as a download client reports it, in the same terms whichever client it came from.
struct TorrentInfo: Sendable {
    /// The torrent's info hash, lowercased.
    let hash: String
    let name: String
    /// 0...1
    let progress: Double
    let phase: ArrDownload.Phase
    /// The client's own word for the state, for error messages.
    let state: String
    let secondsLeft: Int?
    /// Finished downloading and now seeding (or stopped after finishing).
    let isFinished: Bool
}

/// What Mindseerr needs from a download client: read its torrents, and pause, resume or remove one by hash.
protocol TorrentClient: Sendable {
    /// Checks the address and sign-in. Returns the client's version, or throws a readable error.
    func checkConnection() async throws -> String
    func torrents() async throws -> [TorrentInfo]
    func pause(hash: String) async throws
    func resume(hash: String) async throws
    /// Removes the torrent and deletes its downloaded files.
    func delete(hash: String) async throws
}

enum TorrentClients {
    /// The client for a saved download-client service.
    static func make(for service: ArrService) -> TorrentClient {
        switch service.kind {
        case .deluge: return DelugeClient(service: service)
        case .transmission: return TransmissionClient(service: service)
        case .sabnzbd: return SABnzbdClient(service: service)
        default: return QBittorrentClient(service: service)
        }
    }
}

/// Shared by the clients that speak JSON over HTTP.
enum TorrentHTTP {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }

    static func unreachable(_ service: ArrService) -> APIError {
        APIError(status: 0, message: String(localized: "Couldn't reach \(service.name) at \(service.baseURL.absoluteString). Check the address and port."))
    }

    static func confused(_ service: ArrService) -> APIError {
        APIError(status: 0, message: String(localized: "\(service.name) sent a response the app didn't understand. Is that a \(service.kind.name) server?"))
    }
}
