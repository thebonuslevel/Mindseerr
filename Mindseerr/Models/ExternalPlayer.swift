import Foundation

/// The app a movie's Play button opens it in, chosen under Settings → External Player.
/// Infuse is the only one: it documents a link that opens and plays a movie by its TMDB id. Plex's Apple TV app ignores
/// links to a single title (tried on a real Apple TV), and Swiftfin publishes none, so neither is offered.
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case infuse

    static let storageKey = "player.external"

    var id: String { rawValue }

    var name: String { "Infuse" }

    var note: String { "Opens the movie in Infuse by its TMDB id and starts it. Infuse needs the title in its library." }

    /// The link that plays this movie in the player.
    func playURL(tmdbId: Int) -> URL? {
        URL(string: "infuse://movie/\(tmdbId)?play")
    }
}
