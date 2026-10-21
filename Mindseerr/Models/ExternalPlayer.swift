import Foundation

/// What the Play button plays a title in, chosen under Settings → External Player: Apple's built-in player, Infuse,
/// or Off (no Play button). Infuse is the only other app offered: it documents a link that opens and plays a movie by its TMDB id. Plex's Apple TV
/// app ignores links to a single title (tried on a real Apple TV), and Swiftfin publishes none.
enum ExternalPlayer: String, CaseIterable, Identifiable {
    /// Apple's own player, fed by the media server Seerr is set up with. Not an app: it never leaves Mindseerr.
    case native, infuse, off

    static let storageKey = "player.external"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .native: return String(localized: "Apple Player")
        case .infuse: return "Infuse"
        case .off: return "Off"
        }
    }

    var note: String {
        switch self {
        case .native: return String(localized: "Plays the title in Apple's player, streamed from your Plex, Jellyfin or Emby server with your Seerr sign-in. Progress is saved to the server.")
        case .infuse: return String(localized: "Opens the movie in Infuse by its TMDB id and starts it. Infuse needs the title in its library.")
        case .off: return String(localized: "No Play button on movie pages.")
        }
    }

    /// The Play button's text.
    var playLabel: String {
        self == .native ? String(localized: "Play") : String(localized: "Play in \(name)")
    }

    /// Whether movie pages show a Play button.
    var isOn: Bool { self != .off }

    /// The link that plays one episode of a series, by the series' TMDB id.
    func episodeURL(seriesTmdbId: Int, season: Int, episode: Int) -> URL? {
        switch self {
        case .infuse: return URL(string: "infuse://series/\(seriesTmdbId)-\(season)-\(episode)?play")
        case .native, .off: return nil
        }
    }

    /// The link that plays this movie in the player, or nil when it's off.
    func playURL(tmdbId: Int) -> URL? {
        switch self {
        case .infuse: return URL(string: "infuse://movie/\(tmdbId)?play")
        case .native, .off: return nil
        }
    }
}
