import Foundation

/// The Trakt app keys, set in project.yml and baked into Info.plist. Only the Client ID is required:
/// Trakt stopped issuing Client Secrets to new apps in October 2026, and the secret is optional on
/// every sign-in request. Older apps that have one can still add it.
enum TraktConfig {
    static var clientID: String? { value("TraktClientID") }
    static var clientSecret: String? { value("TraktClientSecret") }
    static var isConfigured: Bool { clientID != nil }
    /// Must match the Redirect URI registered on the Trakt app. Sign-in uses a code, so it's only sent
    /// when the app renews the sign-in.
    static var redirectURI: String { value("TraktRedirectURI") ?? "urn:ietf:wg:oauth:2.0:oob" }

    private static func value(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmed
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}

struct TraktDeviceCode: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUrl: String
    let expiresIn: Int
    let interval: Int
}

struct TraktToken: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let createdAt: Int

    var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(createdAt + expiresIn)) }
}

enum TraktPollResult: Sendable {
    case signedIn, pending, slowDown, expired, denied
    case failed(String)
}

private struct TraktIDs: Decodable {
    let trakt: Int?
    let imdb: String?
    let tmdb: Int?
}

private struct TraktMedia: Decodable {
    let title: String?
    let year: Int?
    let ids: TraktIDs
}

private struct TraktListItem: Decodable {
    let listedAt: String?
    let movie: TraktMedia?
    let show: TraktMedia?
}

/// Talks to the Trakt API. Sign-in uses Trakt's device flow: the TV shows a code and the user
/// approves it on Trakt's activation page on another device.
actor TraktClient {
    private let apiBase = URL(string: "https://api.trakt.tv")!
    /// Trakt requires its auth host for every sign-in request (device codes, tokens, refresh, revoke).
    private let authBase = URL(string: "https://auth.trakt.tv")!
    private let session: URLSession
    private var token: TraktToken?
    private static let tokenKey = "traktToken"

    /// A fresh decoder each time: JSONDecoder isn't Sendable, so it can't be a shared static.
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        token = Self.loadToken()
    }

    var isSignedIn: Bool { token != nil }

    // MARK: - Sign-in

    func requestDeviceCode() async throws -> TraktDeviceCode {
        guard let clientID = TraktConfig.clientID else { throw Self.notConfigured }
        let (data, status) = try await send("oauth/device/code", method: "POST", body: ["client_id": clientID])
        guard status == 200 else {
            throw APIError(status: status, message: "Trakt didn't give a sign-in code (error \(status)). Check the Client ID in project.yml.")
        }
        return try Self.decoder.decode(TraktDeviceCode.self, from: data)
    }

    func pollForToken(deviceCode: String) async -> TraktPollResult {
        guard let clientID = TraktConfig.clientID else { return .failed(Self.notConfigured.message) }
        do {
            let (data, status) = try await send("oauth/device/token", method: "POST",
                                                body: Self.withSecret(["code": deviceCode, "client_id": clientID]))
            switch status {
            case 200:
                let newToken = try Self.decoder.decode(TraktToken.self, from: data)
                store(newToken)
                return .signedIn
            case 400: return .pending
            case 429: return .slowDown
            case 404, 409, 410: return .expired
            case 418: return .denied
            default: return .failed("Trakt returned an error (\(status)).")
            }
        } catch {
            return .pending // a network blip; keep polling until the code expires
        }
    }

    func signOut() async {
        if let token, let clientID = TraktConfig.clientID {
            _ = try? await send("oauth/revoke", method: "POST",
                                body: Self.withSecret(["token": token.accessToken, "client_id": clientID]))
        }
        store(nil)
    }

    // MARK: - Data

    func displayName() async throws -> String {
        struct Settings: Decodable {
            struct User: Decodable {
                let username: String
                let name: String?
            }
            let user: User
        }
        let settings: Settings = try await authorizedGET("users/settings")
        if let name = settings.user.name, !name.trimmed.isEmpty { return name }
        return settings.user.username
    }

    func watchlist() async throws -> [WatchlistEntry] {
        let movies: [TraktListItem] = try await authorizedGET("sync/watchlist/movies")
        let shows: [TraktListItem] = try await authorizedGET("sync/watchlist/shows")

        var entries: [(listedAt: String, entry: WatchlistEntry)] = []
        for item in movies {
            guard let media = item.movie else { continue }
            entries.append((item.listedAt ?? "", Self.entry(media, kind: .movie)))
        }
        for item in shows {
            guard let media = item.show else { continue }
            entries.append((item.listedAt ?? "", Self.entry(media, kind: .tv)))
        }
        // Newest additions first, matching how Trakt shows the watchlist.
        return entries.sorted { $0.listedAt > $1.listedAt }.map(\.entry)
    }

    private static func entry(_ media: TraktMedia, kind: MediaType) -> WatchlistEntry {
        let key = media.ids.trakt.map(String.init) ?? media.ids.tmdb.map(String.init) ?? media.ids.imdb ?? (media.title ?? "?")
        return WatchlistEntry(id: "trakt:\(kind.rawValue):\(key)", source: .trakt,
                              title: media.title ?? "Untitled", year: media.year, kind: kind,
                              tmdbId: media.ids.tmdb, imdbId: media.ids.imdb)
    }

    // MARK: - Plumbing

    private func authorizedGET<T: Decodable>(_ path: String) async throws -> T {
        guard let current = token else { throw APIError(status: 401, message: "Sign in to Trakt first.") }
        if current.expiresAt < Date().addingTimeInterval(3600) { try await refresh() }

        var (data, status) = try await send(path, method: "GET", body: nil)
        if status == 401 {
            try await refresh()
            (data, status) = try await send(path, method: "GET", body: nil)
        }
        guard (200..<300).contains(status) else {
            if status == 401 { store(nil) }
            throw APIError(status: status, message: status == 401
                ? "Your Trakt sign-in has expired. Sign in again."
                : "Trakt returned an error (\(status)). Try again in a moment.")
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(status: 0, message: "Trakt sent a response the app didn't understand.")
        }
    }

    private func refresh() async throws {
        guard let current = token, let clientID = TraktConfig.clientID else {
            throw APIError(status: 401, message: "Sign in to Trakt again.")
        }
        // Refresh tokens are single-use: store() below replaces the saved one with the new token.
        let (data, status) = try await send("oauth/token", method: "POST", body: Self.withSecret([
            "refresh_token": current.refreshToken,
            "client_id": clientID,
            "redirect_uri": TraktConfig.redirectURI,
            "grant_type": "refresh_token",
        ]))
        guard status == 200, let newToken = try? Self.decoder.decode(TraktToken.self, from: data) else {
            store(nil)
            throw APIError(status: 401, message: "Your Trakt sign-in has expired. Sign in again.")
        }
        store(newToken)
    }

    /// Adds the Client Secret only for older Trakt apps that have one.
    private static func withSecret(_ body: [String: String]) -> [String: String] {
        guard let secret = TraktConfig.clientSecret else { return body }
        var withSecret = body
        withSecret["client_secret"] = secret
        return withSecret
    }

    private func send(_ path: String, method: String, body: [String: String]?) async throws -> (Data, Int) {
        let base = path.hasPrefix("oauth/") ? authBase : apiBase
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue("Mindseerr/1.0 (Apple TV)", forHTTPHeaderField: "User-Agent")
        if let clientID = TraktConfig.clientID { request.setValue(clientID, forHTTPHeaderField: "trakt-api-key") }
        if let token { request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func store(_ newToken: TraktToken?) {
        token = newToken
        guard let newToken else { Keychain.set(nil, for: Self.tokenKey); return }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? encoder.encode(newToken) {
            Keychain.set(String(decoding: data, as: UTF8.self), for: Self.tokenKey)
        }
    }

    private static func loadToken() -> TraktToken? {
        guard let json = Keychain.get(tokenKey) else { return nil }
        return try? decoder.decode(TraktToken.self, from: Data(json.utf8))
    }

    private static let notConfigured = APIError(status: 0, message:
        "Trakt isn't set up in this build yet. Add your Trakt app's Client ID to project.yml, then build again.")
}
