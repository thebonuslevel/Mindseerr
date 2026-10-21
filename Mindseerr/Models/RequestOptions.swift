import Foundation

// MARK: - Permissions

/// Seerr's permission bits (the same as Overseerr's). Admins have every permission.
enum SeerrPermission: Int {
    case admin = 2
    case manageRequests = 16
    case request4K = 1024
    case request4KMovie = 2048
    case request4KTV = 4096
    case requestAdvanced = 8192
}

extension SeerrUser {
    func has(_ permission: SeerrPermission) -> Bool {
        let p = permissions ?? 0
        return p & SeerrPermission.admin.rawValue != 0 || p & permission.rawValue != 0
    }

    /// Can ask for the 4K copy of this kind of title.
    func canRequest4K(_ type: MediaType) -> Bool {
        has(.request4K) || has(type == .tv ? .request4KTV : .request4KMovie)
    }

    /// Can pick the server, quality profile and root folder for a request (Seerr's "Advanced Requests";
    /// request managers get the same options in Seerr's own request window).
    var canChooseRequestOptions: Bool {
        has(.requestAdvanced) || has(.manageRequests)
    }
}

// MARK: - Radarr / Sonarr servers as Seerr knows them

/// A Radarr or Sonarr server configured in Seerr (`GET /service/radarr`, `/service/sonarr`).
struct RequestServer: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let is4k: Bool
    let isDefault: Bool
    let activeProfileId: Int?
    let activeDirectory: String?
    let activeLanguageProfileId: Int?
}

/// The choices a server offers (`GET /service/radarr/{id}`, `/service/sonarr/{id}`).
struct RequestServerDetails: Decodable, Sendable {
    struct Profile: Decodable, Identifiable, Hashable, Sendable {
        let id: Int
        let name: String
    }
    struct RootFolder: Decodable, Identifiable, Hashable, Sendable {
        let id: Int
        let path: String
        let freeSpace: Double?
    }
    let profiles: [Profile]
    let rootFolders: [RootFolder]
    /// Sonarr v3 only.
    let languageProfiles: [Profile]?
}

/// What gets sent with a request beyond the title and seasons. Nil fields let Seerr use its defaults.
struct RequestOptions: Sendable, Equatable {
    var is4k = false
    var serverId: Int?
    var profileId: Int?
    var rootFolder: String?
    var languageProfileId: Int?
}

extension RequestServerDetails.RootFolder {
    /// "/data/movies · 1.2 TB free"
    var label: String {
        guard let freeSpace, freeSpace > 0 else { return path }
        let free = ByteCountFormatter.string(fromByteCount: Int64(freeSpace), countStyle: .file)
        return String(localized: "\(path)  ·  \(free) free")
    }
}
