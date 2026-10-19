import Foundation

/// The app a movie's Play button opens it in, chosen under Settings → External Player: Infuse, or Off (no Play button).
/// Infuse is the only player offered: it documents a link that opens and plays a movie by its TMDB id. Plex's Apple TV
/// app ignores links to a single title (tried on a real Apple TV), and Swiftfin publishes none.
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case infuse, off

    static let storageKey = "player.external"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .infuse: return "Infuse"
        case .off: return "Off"
        }
    }

    var note: String {
        switch self {
        case .infuse: return "Opens the movie in Infuse by its TMDB id and starts it. Infuse needs the title in its library."
        case .off: return "No Play button on movie pages."
        }
    }

    /// Whether movie pages show a Play button.
    var isOn: Bool { self != .off }

    /// The link that plays one episode of a series, by the series' TMDB id.
    func episodeURL(seriesTmdbId: Int, season: Int, episode: Int) -> URL? {
        switch self {
        case .infuse: return URL(string: "infuse://series/\(seriesTmdbId)-\(season)-\(episode)?play")
        case .off: return nil
        }
    }

    /// The link that plays this movie in the player, or nil when it's off.
    func playURL(tmdbId: Int) -> URL? {
        switch self {
        case .infuse: return URL(string: "infuse://movie/\(tmdbId)?play")
        case .off: return nil
        }
    }
}
