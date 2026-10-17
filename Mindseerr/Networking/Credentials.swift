import Foundation

/// How the user signs in to Seerr. Stored in the Keychain so the app can quietly
/// sign in again when the Seerr session cookie expires.
enum Credentials: Codable, Sendable {
    case plex(token: String)
    case jellyfin(username: String, password: String)
    /// A Seerr account with its own password (Seerr signs these in by email).
    case local(email: String, password: String)
    /// The server's API key. Seerr treats it as the main admin account.
    case apiKey(String)

    var methodName: String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return "Jellyfin / Emby"
        case .local: return "Seerr account"
        case .apiKey: return "API key"
        }
    }

    /// An API key is sent with every request, so there's no session to renew.
    var usesSession: Bool {
        if case .apiKey = self { return false }
        return true
    }

    private static let key = "credentials"
    private static let legacyPlexKey = "plexToken" // used by the first version of the app

    static func load() -> Credentials? {
        if let json = Keychain.get(key),
           let credentials = try? JSONDecoder().decode(Credentials.self, from: Data(json.utf8)) {
            return credentials
        }
        if let token = Keychain.get(legacyPlexKey) { return .plex(token: token) }
        return nil
    }

    static func save(_ credentials: Credentials?) {
        Keychain.set(nil, for: legacyPlexKey)
        guard let credentials, let data = try? JSONEncoder().encode(credentials) else {
            Keychain.set(nil, for: key)
            return
        }
        Keychain.set(String(decoding: data, as: UTF8.self), for: key)
    }
}

/// Which media server the Seerr instance is set up with (from `/settings/public`).
enum MediaServerKind: Sendable {
    case plex, jellyfin, emby, unknown

    init(code: Int?) {
        switch code {
        case 1: self = .plex
        case 2: self = .jellyfin
        case 3: self = .emby
        default: self = .unknown
        }
    }
}

struct PublicSettings: Decodable, Sendable {
    let mediaServerType: Int?
    let applicationTitle: String?
}
