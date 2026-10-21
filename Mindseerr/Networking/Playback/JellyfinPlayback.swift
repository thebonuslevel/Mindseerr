import Foundation

/// Plays from a Jellyfin or Emby server: signs in with the user's name and password, looks the item up, and asks the server
/// for an HLS stream (it converts only what Apple's player can't take as it is).
struct JellyfinPlayback {
    let username: String
    let password: String

    private struct Login {
        let base: URL
        let token: String
        let userID: String
    }

    func session(for info: MediaInfo, episode: MediaServerPlayback.EpisodeID?, title: String) async throws -> PlaybackSession {
        guard let mediaID = info.jellyfinMediaId, !mediaID.isEmpty, let base = Self.base(of: info.mediaUrl) else {
            throw PlaybackError(message: String(localized: "Seerr doesn't list this title on your media server yet."))
        }
        let login = try await signIn(to: base)
        var itemID = mediaID
        if let episode {
            itemID = try await episodeID(ofSeries: mediaID, episode, login)
        }
        let item = try await self.item(itemID, login)
        let playSession = UUID().uuidString

        var components = URLComponents(url: base.appendingPathComponent("Videos/\(itemID)/master.m3u8"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "MediaSourceId", value: item.sourceID),
            URLQueryItem(name: "DeviceId", value: MediaServerPlayback.deviceID),
            URLQueryItem(name: "PlaySessionId", value: playSession),
            URLQueryItem(name: "api_key", value: login.token),
            URLQueryItem(name: "VideoCodec", value: "hevc,h264"),
            URLQueryItem(name: "AudioCodec", value: "aac,ac3,eac3"),
            URLQueryItem(name: "TranscodingMaxAudioChannels", value: "6"),
            URLQueryItem(name: "SegmentContainer", value: "mp4"),
            URLQueryItem(name: "MinSegments", value: "2"),
            URLQueryItem(name: "BreakOnNonKeyFrames", value: "True"),
            URLQueryItem(name: "MaxStreamingBitrate", value: "80000000"),
        ]
        guard let url = components?.url else { throw PlaybackError(message: String(localized: "Couldn't reach Jellyfin.")) }

        return PlaybackSession(url: url, title: title, startSeconds: item.offset, duration: item.duration,
                               reporter: JellyfinReporter(login: (base, login.token), itemID: itemID,
                                                          sourceID: item.sourceID, playSession: playSession))
    }

    // MARK: - Pieces

    /// The server's address from Seerr's link to a title, like https://jelly.example.com/web/index.html#!/details?id=...
    private static func base(of link: String?) -> URL? {
        guard let link, let url = URL(string: link), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let range = components.path.range(of: "/web") { components.path = String(components.path[..<range.lowerBound]) }
        components.fragment = nil
        components.query = nil
        guard let base = components.url else { return nil }
        return base
    }

    private static func headers(_ request: inout URLRequest, token: String? = nil) {
        var value = "MediaBrowser Client=\"Mindseerr\", Device=\"Apple TV\", DeviceId=\"\(MediaServerPlayback.deviceID)\", Version=\"1.4\""
        if let token { value += ", Token=\"\(token)\"" }
        request.setValue(value, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(value, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func signIn(to base: URL) async throws -> Login {
        var request = URLRequest(url: base.appendingPathComponent("Users/AuthenticateByName"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.headers(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let object = try await MediaServerPlayback.json(request, serverName: "Jellyfin") as? [String: Any]
        guard let token = object?["AccessToken"] as? String,
              let userID = (object?["User"] as? [String: Any])?["Id"] as? String else {
            throw PlaybackError(message: String(localized: "Jellyfin didn't accept your sign-in."))
        }
        return Login(base: base, token: token, userID: userID)
    }

    private func get(_ path: String, _ login: Login, query: [URLQueryItem] = []) async throws -> Any {
        var components = URLComponents(url: login.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw PlaybackError(message: String(localized: "Couldn't reach Jellyfin.")) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        Self.headers(&request, token: login.token)
        return try await MediaServerPlayback.json(request, serverName: "Jellyfin")
    }

    private func item(_ id: String, _ login: Login) async throws -> (sourceID: String, offset: Double, duration: Double?) {
        let object = try await get("Users/\(login.userID)/Items/\(id)", login) as? [String: Any]
        let sourceID = (object?["MediaSources"] as? [[String: Any]])?.first?["Id"] as? String ?? id
        let duration = (object?["RunTimeTicks"] as? Double).map { $0 / 10_000_000 }
        var offset = (((object?["UserData"] as? [String: Any])?["PlaybackPositionTicks"] as? Double) ?? 0) / 10_000_000
        if let duration, offset > duration * 0.95 { offset = 0 }
        return (sourceID, offset, duration)
    }

    private func episodeID(ofSeries seriesID: String, _ episode: MediaServerPlayback.EpisodeID, _ login: Login) async throws -> String {
        let object = try await get("Shows/\(seriesID)/Episodes", login, query: [
            URLQueryItem(name: "UserId", value: login.userID),
            URLQueryItem(name: "Season", value: String(episode.season)),
        ]) as? [String: Any]
        let items = object?["Items"] as? [[String: Any]] ?? []
        guard let match = items.first(where: {
            ($0["ParentIndexNumber"] as? Int) == episode.season && ($0["IndexNumber"] as? Int) == episode.number
        }), let id = match["Id"] as? String else {
            throw PlaybackError(message: String(localized: "Jellyfin doesn't have this episode."))
        }
        return id
    }
}

private struct JellyfinReporter: PlaybackReporter {
    let login: (base: URL, token: String)
    let itemID: String
    let sourceID: String
    let playSession: String

    func report(seconds: Double, duration: Double?, state: PlaybackState) async {
        let path = state == .stopped ? "Sessions/Playing/Stopped" : "Sessions/Playing/Progress"
        var request = URLRequest(url: login.base.appendingPathComponent(path), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var value = "MediaBrowser Client=\"Mindseerr\", Device=\"Apple TV\", DeviceId=\"\(MediaServerPlayback.deviceID)\", Version=\"1.4\""
        value += ", Token=\"\(login.token)\""
        request.setValue(value, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(value, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "ItemId": itemID, "MediaSourceId": sourceID, "PlaySessionId": playSession,
            "PositionTicks": Int(seconds * 10_000_000), "IsPaused": state == .paused,
        ] as [String: Any])
        _ = try? await TorrentHTTP.session().data(for: request)
    }
}
