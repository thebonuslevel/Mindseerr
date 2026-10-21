import Foundation

/// The TMDB "API Read Access Token". It identifies the app (not the user) and is what lets a person sign
/// in to their own TMDB account from the TV. The user can enter their own (kept in the Keychain), which
/// wins over one set in project.yml and baked into Info.plist.
enum TMDBConfig {
    private static let keychainKey = "tmdbReadAccessToken"

    static var readToken: String? {
        if let saved = Keychain.get(keychainKey), !saved.trimmed.isEmpty { return saved.trimmed }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TMDBReadAccessToken") as? String else { return nil }
        let value = raw.trimmed
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    /// Saves the user's own token; an empty value removes it.
    static func saveReadToken(_ token: String) {
        Keychain.set(token.trimmed.isEmpty ? nil : token.trimmed, for: keychainKey)
    }
    static var isConfigured: Bool { readToken != nil }
}

/// A sign-in the user approves on themoviedb.org, from a phone or computer.
struct TMDBApproval: Sendable {
    let requestToken: String
    var url: URL { URL(string: "https://www.themoviedb.org/auth/access?request_token=\(requestToken)")! }
    /// TMDB request tokens stop working after 15 minutes.
    let lifetime: TimeInterval = 15 * 60
}

enum TMDBPollResult: Sendable {
    case signedIn, pending, failed(String)
}

private struct TMDBSession: Codable, Sendable {
    let accessToken: String
    let accountId: String
}

private struct TMDBWatchlistPage: Decodable {
    struct Item: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let releaseDate: String?
        let firstAirDate: String?
    }
    let page: Int
    let totalPages: Int
    let results: [Item]
}

/// Talks to the TMDB API on behalf of a signed-in user to read their watchlist. Sign-in is TMDB's v4
/// flow: the TV asks for a request token, the user approves it on themoviedb.org, and the TV swaps it
/// for a user access token.
actor TMDBAccountClient {
    private let base = URL(string: "https://api.themoviedb.org")!
    private let session: URLSession
    private var user: TMDBSession?
    private static let sessionKey = "tmdbSession"

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        if let json = Keychain.get(Self.sessionKey) {
            user = try? Self.decoder.decode(TMDBSession.self, from: Data(json.utf8))
        }
    }

    var isSignedIn: Bool { user != nil }

    // MARK: - Sign-in

    func beginSignIn() async throws -> TMDBApproval {
        guard let appToken = TMDBConfig.readToken else { throw Self.notConfigured }
        let (data, status) = try await send("4/auth/request_token", method: "POST", bearer: appToken, body: [:])
        struct Response: Decodable { let requestToken: String? }
        guard status == 200, let token = (try? Self.decoder.decode(Response.self, from: data))?.requestToken else {
            throw APIError(status: status, message: String(localized: "TMDB didn't give a sign-in link (error \(status)). Check the API Read Access Token you entered."))
        }
        return TMDBApproval(requestToken: token)
    }

    func pollForApproval(_ approval: TMDBApproval) async -> TMDBPollResult {
        guard let appToken = TMDBConfig.readToken else { return .failed(Self.notConfigured.message) }
        do {
            let (data, status) = try await send("4/auth/access_token", method: "POST", bearer: appToken,
                                                body: ["request_token": approval.requestToken])
            struct Response: Decodable {
                let accessToken: String?
                let accountId: String?
            }
            if status == 200, let r = try? Self.decoder.decode(Response.self, from: data),
               let token = r.accessToken, let account = r.accountId {
                store(TMDBSession(accessToken: token, accountId: account))
                return .signedIn
            }
            // Until the user approves, TMDB answers with an error; keep polling.
            return .pending
        } catch {
            return .pending // a network blip; keep polling until the link expires
        }
    }

    func signOut() async {
        if let user, let appToken = TMDBConfig.readToken {
            _ = try? await send("4/auth/access_token", method: "DELETE", bearer: appToken,
                                body: ["access_token": user.accessToken])
        }
        store(nil)
    }

    // MARK: - Data

    func displayName() async -> String? {
        guard let user else { return nil }
        struct Account: Decodable {
            let username: String?
            let name: String?
        }
        guard let (data, status) = try? await send("3/account", method: "GET", bearer: user.accessToken, body: nil),
              status == 200, let account = try? Self.decoder.decode(Account.self, from: data) else { return nil }
        if let name = account.name, !name.trimmed.isEmpty { return name }
        return account.username
    }

    func watchlist() async throws -> [WatchlistEntry] {
        let movies = try await pages("movie", kind: .movie)
        let shows = try await pages("tv", kind: .tv)
        return movies + shows
    }

    /// Every page of one watchlist, newest additions first.
    private func pages(_ path: String, kind: MediaType) async throws -> [WatchlistEntry] {
        guard let user else { throw APIError(status: 401, message: String(localized: "Sign in to TMDB first.")) }
        var entries: [WatchlistEntry] = []
        var page = 1
        var totalPages = 1
        while page <= totalPages, page <= 50 {
            let (data, status) = try await send(
                "4/account/\(user.accountId)/\(path)/watchlist?page=\(page)&sort_by=created_at.desc",
                method: "GET", bearer: user.accessToken, body: nil)
            guard status == 200 else {
                if status == 401 { store(nil) }
                throw APIError(status: status, message: status == 401
                    ? "Your TMDB sign-in has expired. Sign in again."
                    : "TMDB returned an error (\(status)). Try again in a moment.")
            }
            guard let decoded = try? Self.decoder.decode(TMDBWatchlistPage.self, from: data) else {
                throw APIError(status: 0, message: String(localized: "TMDB sent a response the app didn't understand."))
            }
            totalPages = decoded.totalPages
            for item in decoded.results {
                let date = kind == .movie ? item.releaseDate : item.firstAirDate
                entries.append(WatchlistEntry(
                    id: "tmdb:\(kind.rawValue):\(item.id)", source: .tmdb,
                    title: (kind == .movie ? item.title : item.name) ?? item.title ?? item.name ?? "Untitled",
                    year: date.flatMap { Int($0.prefix(4)) }, kind: kind, tmdbId: item.id, imdbId: nil))
            }
            page += 1
        }
        return entries
    }

    // MARK: - Plumbing

    private func send(_ path: String, method: String, bearer: String, body: [String: String]?) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: base) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func store(_ newSession: TMDBSession?) {
        user = newSession
        guard let newSession else { Keychain.set(nil, for: Self.sessionKey); return }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? encoder.encode(newSession) {
            Keychain.set(String(decoding: data, as: UTF8.self), for: Self.sessionKey)
        }
    }

    private static let notConfigured = APIError(status: 0, message:
        "TMDB isn't set up in this build yet. Enter your TMDB API Read Access Token on the TMDB tab.")
}
