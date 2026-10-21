import Foundation

/// Where the player is in a title, as reported back to the media server so it can resume and mark things watched.
enum PlaybackState: String, Sendable {
    case playing, paused, stopped
}

/// Tells the media server how far along playback is.
protocol PlaybackReporter: Sendable {
    func report(seconds: Double, duration: Double?, state: PlaybackState) async
}

/// One title ready to play in Apple's player: a stream address and where to start.
struct PlaybackSession: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let title: String
    /// Where the server says the viewer left off; 0 to start from the beginning.
    let startSeconds: Double
    let duration: Double?
    let reporter: PlaybackReporter
}

struct PlaybackError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Finds a title on the media server Seerr is set up with (Plex, Jellyfin or Emby) and builds a stream for Apple's player.
///
/// Seerr says which item on the server a title is (`ratingKey` for Plex, `jellyfinMediaId` for Jellyfin and Emby), and
/// the server's address comes from the link Seerr keeps to it. The sign-in is the one used for Seerr.
enum MediaServerPlayback {
    /// A single episode, by season and episode number.
    struct EpisodeID: Sendable {
        let season: Int
        let number: Int
    }

    static func session(for info: MediaInfo?, episode: EpisodeID?, title: String) async throws -> PlaybackSession {
        guard let info else {
            throw PlaybackError(message: String(localized: "Seerr doesn't list this title on your media server yet."))
        }
        switch Credentials.load() {
        case .plex(let token)?:
            return try await PlexPlayback(token: token).session(for: info, episode: episode, title: title)
        case .jellyfin(let username, let password)?:
            return try await JellyfinPlayback(username: username, password: password)
                .session(for: info, episode: episode, title: title)
        default:
            throw PlaybackError(message: String(localized: "The built-in player uses your Plex, Jellyfin or Emby sign-in. Sign in to Seerr with your media server account, or choose another player in Settings → External Player."))
        }
    }

    /// A stable ID for this Apple TV, so the media server sees one device and not a new one each time.
    static var deviceID: String {
        let key = "playback.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    /// One JSON request to a media server, with a readable error when it can't be reached or says no.
    static func json(_ request: URLRequest, serverName: String) async throws -> Any {
        let data: Data
        let status: Int
        do {
            let (body, response) = try await TorrentHTTP.session().data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw PlaybackError(message: String(localized: "Couldn't reach \(serverName). Check that your Apple TV is on the same network, or that the server is reachable."))
        }
        guard (200..<300).contains(status) else {
            throw PlaybackError(message: status == 401 || status == 403
                                ? String(localized: "\(serverName) didn't accept your sign-in.")
                                : String(localized: "\(serverName) returned error \(status)."))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw PlaybackError(message: String(localized: "\(serverName) sent a response the app didn't understand."))
        }
        return object
    }
}
