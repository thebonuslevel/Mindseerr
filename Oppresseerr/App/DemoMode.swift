#if DEBUG
import Foundation

/// Debug-only demo mode, used to take README screenshots with invented content.
///
/// Launch the app with `OPPRESSEERR_DEMO=<base URL>` (e.g. `http://127.0.0.1:8765`) pointing at the
/// stand-in server in `Tools/demo-server/`. The app then reads Seerr from `<base>`, poster art from
/// `<base>/img`, and Sonarr/Radarr from `<base>/sonarr` and `<base>/radarr`. Nothing is saved: the real
/// server address, sign-in and Sonarr/Radarr connections are left untouched. Not compiled into release builds.
enum DemoMode {
    private static let base: String? = {
        guard let raw = ProcessInfo.processInfo.environment["OPPRESSEERR_DEMO"]?.trimmed, !raw.isEmpty else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }()

    static var seerrURL: URL? { base.flatMap(URL.init(string:)) }

    /// Poster/backdrop paths are appended to this, replacing image.tmdb.org.
    static var imageBase: String? { base.map { $0 + "/img" } }

    static var arrServices: [ArrService]? {
        guard let base else { return nil }
        return [ArrKind.sonarr, .radarr].compactMap { kind in
            URL(string: "\(base)/\(kind.rawValue)").map {
                ArrService(kind: kind, name: kind.name, baseURL: $0, apiKey: "demo")
            }
        }
    }
}
#endif
