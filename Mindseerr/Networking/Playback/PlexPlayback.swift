import Foundation

/// Plays from a Plex server: finds the server through plex.tv with the user's token, looks up the item, and asks the server
/// for an HLS stream (it copies the video and audio when Apple's player can take them, and converts what it can't).
struct PlexPlayback {
    let token: String

    private struct Server {
        let base: URL
        let token: String
    }

    func session(for info: MediaInfo, episode: MediaServerPlayback.EpisodeID?, title: String) async throws -> PlaybackSession {
        guard let ratingKey = info.ratingKey, !ratingKey.isEmpty else {
            throw PlaybackError(message: String(localized: "Seerr doesn't list this title on your media server yet."))
        }
        let server = try await connect(machineID: Self.machineID(in: info.plexUrl ?? info.mediaUrl))
        var itemKey = ratingKey
        if let episode {
            itemKey = try await episodeKey(of: ratingKey, episode, on: server)
        }
        let item = try await metadata(of: itemKey, on: server)
        let session = UUID().uuidString

        var components = URLComponents(url: server.base.appendingPathComponent("video/:/transcode/universal/start.m3u8"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(itemKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "subtitles", value: "auto"),
            URLQueryItem(name: "location", value: "lan"),
            URLQueryItem(name: "maxVideoBitrate", value: "40000"),
            URLQueryItem(name: "session", value: session),
        ] + Self.identity(token: server.token)
        guard let url = components?.url else { throw PlaybackError(message: String(localized: "Couldn't reach Plex.")) }

        return PlaybackSession(url: url, title: title, startSeconds: item.offset, duration: item.duration,
                               reporter: PlexReporter(server: server.base, token: server.token, ratingKey: itemKey,
                                                      duration: item.duration, session: session))
    }

    // MARK: - Finding the server

    /// The ID of the server in a link like https://app.plex.tv/desktop#!/server/<id>/details?key=...
    private static func machineID(in link: String?) -> String? {
        guard let link, let range = link.range(of: "/server/") else { return nil }
        let rest = link[range.upperBound...]
        return String(rest.prefix { $0 != "/" })
    }

    private static func identity(token: String) -> [URLQueryItem] {
        [URLQueryItem(name: "X-Plex-Token", value: token),
         URLQueryItem(name: "X-Plex-Client-Identifier", value: MediaServerPlayback.deviceID),
         URLQueryItem(name: "X-Plex-Product", value: "Mindseerr"),
         URLQueryItem(name: "X-Plex-Platform", value: "tvOS"),
         URLQueryItem(name: "X-Plex-Device", value: "Apple TV")]
    }

    private static func request(_ url: URL, token: String, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(MediaServerPlayback.deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("Mindseerr", forHTTPHeaderField: "X-Plex-Product")
        return request
    }

    /// Looks the server up on plex.tv and picks the first address that answers, preferring the home network.
    private func connect(machineID: String?) async throws -> Server {
        let resourcesURL = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        let object = try await MediaServerPlayback.json(Self.request(resourcesURL, token: token), serverName: "Plex")
        let devices = (object as? [[String: Any]] ?? []).filter { ($0["provides"] as? String)?.contains("server") == true }
        guard let device = devices.first(where: { machineID == nil || $0["clientIdentifier"] as? String == machineID }) else {
            throw PlaybackError(message: String(localized: "Your Plex account can't see this server."))
        }
        let accessToken = device["accessToken"] as? String ?? token
        let connections = (device["connections"] as? [[String: Any]] ?? []).sorted { a, b in
            func rank(_ c: [String: Any]) -> Int { c["relay"] as? Bool == true ? 2 : (c["local"] as? Bool == true ? 0 : 1) }
            return rank(a) < rank(b)
        }
        for connection in connections {
            guard let uri = connection["uri"] as? String, let base = URL(string: uri) else { continue }
            let probe = Self.request(base.appendingPathComponent("identity"), token: accessToken, timeout: 4)
            if let (_, response) = try? await TorrentHTTP.session().data(for: probe),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return Server(base: base, token: accessToken)
            }
        }
        throw PlaybackError(message: String(localized: "Couldn't reach Plex. Check that your Apple TV is on the same network, or that the server is reachable."))
    }

    // MARK: - Looking things up

    private func metadata(of key: String, on server: Server) async throws -> (offset: Double, duration: Double?) {
        let object = try await MediaServerPlayback.json(
            Self.request(server.base.appendingPathComponent("library/metadata/\(key)"), token: server.token), serverName: "Plex")
        let container = (object as? [String: Any])?["MediaContainer"] as? [String: Any]
        guard let item = (container?["Metadata"] as? [[String: Any]])?.first else {
            throw PlaybackError(message: String(localized: "Plex doesn't have this title."))
        }
        let duration = (item["duration"] as? Double).map { $0 / 1000 }
        var offset = ((item["viewOffset"] as? Double) ?? 0) / 1000
        // Near the end counts as watched, so start over.
        if let duration, offset > duration * 0.95 { offset = 0 }
        return (offset, duration)
    }

    /// The Plex item for one episode of a show, found by season and episode number.
    private func episodeKey(of showKey: String, _ episode: MediaServerPlayback.EpisodeID, on server: Server) async throws -> String {
        let object = try await MediaServerPlayback.json(
            Self.request(server.base.appendingPathComponent("library/metadata/\(showKey)/allLeaves"), token: server.token),
            serverName: "Plex")
        let container = (object as? [String: Any])?["MediaContainer"] as? [String: Any]
        let leaves = container?["Metadata"] as? [[String: Any]] ?? []
        guard let match = leaves.first(where: {
            ($0["parentIndex"] as? Int) == episode.season && ($0["index"] as? Int) == episode.number
        }), let key = match["ratingKey"] as? String else {
            throw PlaybackError(message: String(localized: "Plex doesn't have this episode."))
        }
        return key
    }
}

private struct PlexReporter: PlaybackReporter {
    let server: URL
    let token: String
    let ratingKey: String
    let duration: Double?
    let session: String

    func report(seconds: Double, duration: Double?, state: PlaybackState) async {
        var components = URLComponents(url: server.appendingPathComponent(":/timeline"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(Int(seconds * 1000))),
            URLQueryItem(name: "duration", value: String(Int((duration ?? self.duration ?? 0) * 1000))),
            URLQueryItem(name: "X-Plex-Token", value: token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: MediaServerPlayback.deviceID),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: session),
        ]
        guard let url = components?.url else { return }
        _ = try? await TorrentHTTP.session().data(from: url)
    }
}
