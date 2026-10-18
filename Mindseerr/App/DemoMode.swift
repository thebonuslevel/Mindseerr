#if DEBUG
import Foundation

/// Debug-only demo mode, used to take README screenshots with invented content.
///
/// Launch the app with `MINDSEERR_DEMO=<base URL>` (e.g. `http://127.0.0.1:8765`) pointing at the
/// stand-in server in `Tools/demo-server/`. The app then reads Seerr from `<base>`, poster art from
/// `<base>/img`, and Sonarr/Radarr from `<base>/sonarr` and `<base>/radarr`. Nothing is saved: the real
/// server address, sign-in and Sonarr/Radarr connections are left untouched. Not compiled into release builds.
enum DemoMode {
    private static let base: String? = {
        guard let raw = ProcessInfo.processInfo.environment["MINDSEERR_DEMO"]?.trimmed, !raw.isEmpty else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }()

    static var seerrURL: URL? { base.flatMap(URL.init(string:)) }

    /// Poster/backdrop paths are appended to this, replacing image.tmdb.org.
    static var imageBase: String? { base.map { $0 + "/img" } }

    /// A made-up Trakt watchlist of titles from the demo server, for the Watchlists screenshots.
    static var watchlist: [WatchlistEntry]? {
        guard base != nil else { return nil }
        let titles: [(Int, MediaType, String, Int)] = [
            (9101, .tv, "Deep Station", 2025), (9008, .movie, "Paper Moons", 2024), (9006, .movie, "Night of the Long Tide", 2023),
            (9010, .movie, "The Quiet Fathoms", 2025), (9002, .movie, "Saltwater Saints", 2024), (9105, .tv, "Lantern Street", 2025),
            (9103, .tv, "Orbital Gardens", 2022), (9011, .movie, "Cinder Bloom", 2024), (9104, .tv, "Brine & Bone", 2025),
            (9012, .movie, "Echoes Beneath", 2023), (9007, .movie, "Glass Harbor", 2021), (9106, .tv, "Signal Fires", 2025),
        ]
        return titles.map { id, kind, title, year in
            WatchlistEntry(id: "trakt:\(kind.rawValue):\(id)", source: .trakt, title: title, year: year,
                           kind: kind, tmdbId: id, imdbId: nil)
        }
    }

    static var arrServices: [ArrService]? {
        guard let base else { return nil }
        // MINDSEERR_DEMO_SERVICES=qbittorrent (comma-separated kinds) limits which services the demo has,
        // for showing qBittorrent on its own.
        let wanted = ProcessInfo.processInfo.environment["MINDSEERR_DEMO_SERVICES"]?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return [ArrKind.sonarr, .radarr, .qbittorrent].filter { wanted?.contains($0.rawValue) ?? true }.compactMap { kind in
            URL(string: "\(base)/\(kind.rawValue)").map {
                ArrService(kind: kind, name: kind.name, baseURL: $0, apiKey: kind == .qbittorrent ? "qbt_demo" : "demo")
            }
        }
    }
}
#endif
