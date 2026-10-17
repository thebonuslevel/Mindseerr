import Foundation

/// The TheTVDB API key. It identifies the app; each person also adds their own subscriber PIN
/// (from thetvdb.com/dashboard/account/apikey) to sign in. The user can enter their own key (kept in
/// the Keychain), which wins over one set in project.yml and baked into Info.plist.
enum TVDBConfig {
    private static let keychainKey = "tvdbAPIKey"

    static var apiKey: String? {
        if let saved = Keychain.get(keychainKey), !saved.trimmed.isEmpty { return saved.trimmed }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TVDBAPIKey") as? String else { return nil }
        let value = raw.trimmed
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
    static var isConfigured: Bool { apiKey != nil }

    /// Saves the user's own key; an empty value removes it.
    static func saveAPIKey(_ key: String) {
        Keychain.set(key.trimmed.isEmpty ? nil : key.trimmed, for: keychainKey)
    }
}

private struct TVDBEnvelope<T: Decodable>: Decodable {
    let data: T?
}

private struct TVDBFavorites: Decodable {
    let series: [Int]?
    let movies: [Int]?
}

private struct TVDBRemoteID: Decodable {
    let id: String?
    let sourceName: String?
}

private struct TVDBTitle: Decodable {
    let id: Int
    let name: String?
    let year: String?
    let remoteIds: [TVDBRemoteID]?
}

/// Talks to the TheTVDB v4 API. TheTVDB's "watchlist" is the user's favorites. It lists series and
/// movies by TheTVDB id, so each one is looked up once to find its TMDB (or IMDb) id for Seerr.
actor TVDBClient {
    private let base = URL(string: "https://api4.thetvdb.com/v4/")!
    private let session: URLSession
    private var token: String?
    private var pin: String?
    private static let pinKey = "tvdbPin"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        pin = Keychain.get(Self.pinKey)
    }

    var isSignedIn: Bool { pin != nil }

    // MARK: - Sign-in

    /// Checks the PIN with TheTVDB and keeps it, so the app can sign in again when the token lapses.
    func signIn(pin newPin: String) async throws {
        pin = newPin
        do {
            try await login()
        } catch {
            pin = nil
            token = nil
            throw error
        }
        Keychain.set(newPin, for: Self.pinKey)
    }

    func signOut() {
        pin = nil
        token = nil
        Keychain.set(nil, for: Self.pinKey)
    }

    private func login() async throws {
        guard let apiKey = TVDBConfig.apiKey else { throw Self.notConfigured }
        guard let pin else { throw APIError(status: 401, message: "Add your TheTVDB PIN first.") }
        let (data, status) = try await send("login", method: "POST", authorized: false,
                                            body: ["apikey": apiKey, "pin": pin])
        guard status == 200, let newToken = (try? JSONDecoder().decode(TVDBEnvelope<[String: String]>.self, from: data))?.data?["token"] else {
            throw APIError(status: status, message: status == 401
                ? "TheTVDB didn't accept that PIN. Copy it again from thetvdb.com/dashboard/account/apikey."
                : "TheTVDB returned an error (\(status)). Try again in a moment.")
        }
        token = newToken
    }

    // MARK: - Data

    func watchlist(progress: @Sendable (String) async -> Void) async throws -> [WatchlistEntry] {
        let favorites: TVDBFavorites = try await get("user/favorites")
        let jobs = (favorites.movies ?? []).map { (id: $0, kind: MediaType.movie) }
                 + (favorites.series ?? []).map { (id: $0, kind: MediaType.tv) }
        guard !jobs.isEmpty else { return [] }
        await progress("Looking up \(jobs.count) titles on TheTVDB…")
        // Warm the token once so the parallel lookups below don't each log in.
        if token == nil { try await login() }

        let client = self
        let results = await boundedMap(jobs, limit: 6) { job in
            await client.entry(id: job.id, kind: job.kind)
        }
        // Favorites come back as bare ids; newest-added order isn't available, so keep movies then series.
        return results.compactMap { $0 }
    }

    private func entry(id: Int, kind: MediaType) async -> WatchlistEntry? {
        let path = kind == .movie ? "movies/\(id)/extended?short=true" : "series/\(id)/extended?short=true"
        guard let title: TVDBTitle = try? await get(path) else { return nil }
        let ids = title.remoteIds ?? []
        let tmdb = ids.first { $0.sourceName == "TheMovieDB.com" }?.id.flatMap(Int.init)
        let imdb = ids.first { $0.sourceName == "IMDB" }?.id
        return WatchlistEntry(id: "tvdb:\(kind.rawValue):\(id)", source: .tvdb,
                              title: title.name ?? "Untitled", year: title.year.flatMap { Int($0.prefix(4)) },
                              kind: kind, tmdbId: tmdb, imdbId: imdb)
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        if token == nil { try await login() }
        var (data, status) = try await send(path, method: "GET", authorized: true, body: nil)
        if status == 401 {
            try await login()
            (data, status) = try await send(path, method: "GET", authorized: true, body: nil)
        }
        guard (200..<300).contains(status) else {
            throw APIError(status: status, message: status == 401
                ? "Your TheTVDB sign-in has expired. Connect again."
                : "TheTVDB returned an error (\(status)). Try again in a moment.")
        }
        guard let value = (try? JSONDecoder().decode(TVDBEnvelope<T>.self, from: data))?.data else {
            throw APIError(status: 0, message: "TheTVDB sent a response the app didn't understand.")
        }
        return value
    }

    private func send(_ path: String, method: String, authorized: Bool, body: [String: String]?) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: base) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static let notConfigured = APIError(status: 0, message:
        "TheTVDB isn't set up in this build yet. Enter your TheTVDB API key on the TheTVDB tab.")
}
