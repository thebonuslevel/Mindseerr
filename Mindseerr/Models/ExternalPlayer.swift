import Foundation

/// The app a title's Play button opens it in, chosen under Settings → External Player.
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case infuse, plex, swiftfin

    static let storageKey = "player.external"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .infuse: return "Infuse"
        case .plex: return "Only opens Plex: its Apple TV app ignores links to a single movie, so you pick the movie there. Infuse can play from your Plex library directly."
        case .swiftfin: return "Swiftfin"
        }
    }

    var note: String {
        switch self {
        case .infuse: return "Opens the movie in Infuse by its TMDB id. Infuse needs the title in its library."
        case .plex: return "Opens Plex and plays the movie from your Plex server. Needs a Plex server in Seerr."
        case .swiftfin: return "Opens Swiftfin. It doesn't publish a link to a single title, so you pick the movie there."
        }
    }

    /// The link that plays this movie in the player, or nil when it can't be worked out (Plex without a server link).
    func playURL(tmdbId: Int, info: MediaInfo?) -> URL? {
        switch self {
        case .infuse:
            return URL(string: "infuse://movie/\(tmdbId)?play")
        case .plex:
            // Plex's Apple TV app ignores plex:// links to a title (tried play and preplay links, with Plex open and closed),
            // so all that can be done is to open it.
            return URL(string: "plex://")
        case .swiftfin: return "Swiftfin"
        }
    }

    var note: String {
        switch self {
        case .infuse: return "Opens the movie in Infuse by its TMDB id. Infuse needs the title in its library."
        case .plex: return "Opens Plex and plays the movie from your Plex server. Needs a Plex server in Seerr."
        case .swiftfin: return "Opens Swiftfin. It doesn't publish a link to a single title, so you pick the movie there."
        }
    }

    /// The link that plays this movie in the player, or nil when it can't be worked out (Plex without a server link).
    func playURL(tmdbId: Int, info: MediaInfo?) -> URL? {
        switch self {
        case .infuse:
            return URL(string: "infuse://movie/\(tmdbId)?play")
        case .plex:
            // Seerr's app link carries the item's key and the server; fall back to its web link, which carries the same.
            guard let source = info?.iOSPlexUrl ?? info?.plexUrl else { return nil }
            return Self.plexURL(from: source)
        case .swiftfin:
            return URL(string: "swiftfin://")
        }
    }

    /// `plex://play/?metadataKey=%2Flibrary%2Fmetadata%2F123&server=<machine id>`, from either of Seerr's Plex links.
    static func plexURL(from link: String) -> URL? {
        var key: String?
        var server: String?
        if let components = URLComponents(string: link) {
            key = components.queryItems?.first { $0.name == "metadataKey" || $0.name == "key" }?.value
            server = components.queryItems?.first { $0.name == "server" }?.value
            // The web link keeps its parameters after a "#!/": .../server/<id>/details?key=...
            if let fragment = components.fragment, key == nil || server == nil,
               let inner = URLComponents(string: "x:" + fragment.replacingOccurrences(of: "!", with: "")) {
                key = key ?? inner.queryItems?.first { $0.name == "key" }?.value
                if server == nil, let range = fragment.range(of: "/server/") {
                    server = String(fragment[range.upperBound...].prefix { $0 != "/" })
                }
            }
        }
        guard let key, let server, !key.isEmpty, !server.isEmpty else { return nil }
        // Plex wants the item's path percent-encoded ("%2Flibrary%2Fmetadata%2F123"), as Seerr stores it.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let encodedServer = server.addingPercentEncoding(withAllowedCharacters: allowed) ?? server
        return URL(string: "plex://play/?metadataKey=\(encodedKey)&server=\(encodedServer)")
    }
}
