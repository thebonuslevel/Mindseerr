import Foundation

struct SeerrUser: Decodable, Identifiable, Sendable {
    let id: Int
    let displayName: String?
    let email: String?
    let plexUsername: String?
    let jellyfinUsername: String?
    let username: String?
    let avatar: String?
    let permissions: Int?

    /// Admins and users with Manage Requests can approve, decline, retry and delete requests.
    var canManageRequests: Bool {
        let p = permissions ?? 0
        return p & 2 != 0 || p & 16 != 0
    }

    var name: String {
        [displayName, plexUsername, jellyfinUsername, username, email]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "User"
    }
}

struct RequestCounts: Decodable, Sendable {
    let total: Int?
    let pending: Int?
    let approved: Int?
    let declined: Int?
    let processing: Int?
    let available: Int?
}

struct ServerStatus: Decodable, Sendable {
    let version: String
    let commitTag: String?
    let updateAvailable: Bool?
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
