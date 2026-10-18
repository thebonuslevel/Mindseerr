import Foundation

struct APIError: LocalizedError, Sendable {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

enum DiscoverSection: String, CaseIterable, Identifiable, Sendable {
    case trending, popularMovies, upcomingMovies, popularTV, upcomingTV

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trending: return "Trending"
        case .popularMovies: return "Popular Movies"
        case .upcomingMovies: return "Upcoming Movies"
        case .popularTV: return "Popular Series"
        case .upcomingTV: return "Upcoming Series"
        }
    }

    var path: String {
        switch self {
        case .trending: return "discover/trending"
        case .popularMovies: return "discover/movies"
        case .upcomingMovies: return "discover/movies/upcoming"
        case .popularTV: return "discover/tv"
        case .upcomingTV: return "discover/tv/upcoming"
        }
    }
}

/// Talks to the Seerr REST API (`/api/v1`).
///
/// Seerr authenticates with an express session cookie (`connect.sid`). The cookie is managed by hand
/// rather than through `HTTPCookieStorage` so it can live in the Keychain. When the session expires,
/// the client signs in again with the stored credentials (Plex token or Jellyfin login) and retries once.
actor SeerrClient {
    let baseURL: URL
    private var sessionCookie: String?
    private let credentials: Credentials?
    private let apiKey: String?
    private let onSessionChange: @Sendable (String?) -> Void
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var detailCache: [MediaRoute: MediaDetail] = [:]
    private var serverCache: [MediaType: [RequestServer]] = [:]
    private var reauthTask: Task<Void, Error>?

    init(
        baseURL: URL,
        sessionCookie: String?,
        credentials: Credentials?,
        onSessionChange: @escaping @Sendable (String?) -> Void = { _ in }
    ) {
        self.baseURL = baseURL
        self.sessionCookie = sessionCookie
        self.credentials = credentials
        if case .apiKey(let key) = credentials { self.apiKey = key } else { self.apiKey = nil }
        self.onSessionChange = onSessionChange

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config)
    }

    // MARK: - Endpoints

    func status() async throws -> ServerStatus {
        try await send("status", authenticated: false)
    }

    func publicSettings() async throws -> PublicSettings {
        try await send("settings/public", authenticated: false)
    }

    @discardableResult
    func login(with credentials: Credentials) async throws -> SeerrUser {
        switch credentials {
        case .plex(let token):
            return try await send("auth/plex", method: "POST", body: ["authToken": token],
                                  authenticated: false, allowReauth: false)
        case .jellyfin(let username, let password):
            // Seerr uses the same endpoint for Jellyfin and Emby servers.
            return try await send("auth/jellyfin", method: "POST",
                                  body: ["username": username, "password": password],
                                  authenticated: false, allowReauth: false)
        case .local(let email, let password):
            return try await send("auth/local", method: "POST",
                                  body: ["email": email, "password": password],
                                  authenticated: false, allowReauth: false)
        case .apiKey(let key):
            // There's no sign-in call for a key; checking who it belongs to validates it.
            return try await send("auth/me", allowReauth: false, apiKeyOverride: key)
        }
    }

    func currentUser() async throws -> SeerrUser {
        try await send("auth/me")
    }

    func logout() async {
        if sessionCookie != nil {
            _ = try? await perform("auth/logout", method: "POST", query: [:], body: nil,
                                   authenticated: true, allowReauth: false)
        }
        updateCookie(nil)
        detailCache.removeAll()
    }

    func discover(_ section: DiscoverSection, page: Int) async throws -> PagedResponse<MediaResult> {
        try await send(section.path, query: ["page": "\(page)"])
    }

    func search(_ query: String, page: Int = 1) async throws -> PagedResponse<MediaResult> {
        try await send("search", query: ["query": query, "page": "\(page)"])
    }

    func detail(for route: MediaRoute, useCache: Bool = true) async throws -> MediaDetail {
        if useCache, let cached = detailCache[route] { return cached }
        let path = route.type == .tv ? "tv/\(route.tmdbId)" : "movie/\(route.tmdbId)"
        let detail: MediaDetail = try await send(path)
        detailCache[route] = detail
        return detail
    }

    /// Requests a movie, or specific seasons of a series.
    func request(_ route: MediaRoute, seasons: [Int]? = nil, options: RequestOptions = RequestOptions()) async throws -> MediaRequest {
        struct Body: Encodable {
            let mediaType: String
            let mediaId: Int
            let seasons: [Int]?
            let is4k: Bool
            // Left out when nil, so Seerr uses the server's defaults.
            let serverId: Int?
            let profileId: Int?
            let rootFolder: String?
            let languageProfileId: Int?
        }
        let body = Body(mediaType: route.type.rawValue, mediaId: route.tmdbId,
                        seasons: route.type == .tv ? seasons : nil, is4k: options.is4k,
                        serverId: options.serverId, profileId: options.profileId,
                        rootFolder: options.rootFolder,
                        languageProfileId: route.type == .tv ? options.languageProfileId : nil)
        let created: MediaRequest = try await send("request", method: "POST", body: body)
        detailCache[route] = nil
        return created
    }

    // MARK: - Request options

    /// The Radarr (movies) or Sonarr (series) servers set up in Seerr, standard and 4K.
    func requestServers(for type: MediaType) async throws -> [RequestServer] {
        if let cached = serverCache[type] { return cached }
        let servers: [RequestServer] = try await send(type == .tv ? "service/sonarr" : "service/radarr")
        serverCache[type] = servers
        return servers
    }

    /// Quality profiles, root folders (and Sonarr language profiles) for one server.
    func requestServerDetails(for type: MediaType, serverId: Int) async throws -> RequestServerDetails {
        try await send(type == .tv ? "service/sonarr/\(serverId)" : "service/radarr/\(serverId)")
    }

    // MARK: - Related titles

    enum RelatedList: String, Sendable {
        case recommendations, similar
    }

    func related(_ list: RelatedList, to route: MediaRoute, page: Int = 1) async throws -> PagedResponse<MediaResult> {
        let base = route.type == .tv ? "tv" : "movie"
        return try await send("\(base)/\(route.tmdbId)/\(list.rawValue)", query: ["page": "\(page)"])
    }

    // MARK: - Managing requests (needs the Manage Requests permission)

    enum RequestFilter: String, CaseIterable, Identifiable, Sendable {
        case pending, processing, failed, available, all

        var id: String { rawValue }
        var title: String {
            switch self {
            case .pending: return "Pending"
            case .processing: return "Processing"
            case .failed: return "Failed"
            case .available: return "Available"
            case .all: return "All"
            }
        }
    }

    /// One user's own requests, newest first.
    func requests(for userId: Int, skip: Int, take: Int = 20) async throws -> RequestPage {
        try await send("request", query: [
            "take": "\(take)",
            "skip": "\(skip)",
            "sort": "added",
            "filter": "all",
            "requestedBy": "\(userId)",
        ])
    }

    func allRequests(filter: RequestFilter, skip: Int, take: Int = 20) async throws -> RequestPage {
        try await send("request", query: [
            "take": "\(take)",
            "skip": "\(skip)",
            "sort": "added",
            "filter": filter.rawValue,
        ])
    }

    func requestCounts() async throws -> RequestCounts {
        try await send("request/count")
    }

    @discardableResult
    func approve(requestID: Int) async throws -> MediaRequest {
        let request: MediaRequest = try await send("request/\(requestID)/approve", method: "POST")
        detailCache.removeAll()
        return request
    }

    @discardableResult
    func decline(requestID: Int) async throws -> MediaRequest {
        let request: MediaRequest = try await send("request/\(requestID)/decline", method: "POST")
        detailCache.removeAll()
        return request
    }

    @discardableResult
    func retry(requestID: Int) async throws -> MediaRequest {
        try await send("request/\(requestID)/retry", method: "POST")
    }

    func deleteRequest(id: Int) async throws {
        _ = try await perform("request/\(id)", method: "DELETE", query: [:], body: nil,
                              authenticated: true, allowReauth: true)
        detailCache.removeAll()
    }

    // MARK: - Plumbing

    private func send<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: (any Encodable)? = nil,
        authenticated: Bool = true,
        allowReauth: Bool = true,
        apiKeyOverride: String? = nil
    ) async throws -> T {
        let data = try await perform(path, method: method, query: query, body: body,
                                     authenticated: authenticated, allowReauth: allowReauth,
                                     apiKeyOverride: apiKeyOverride)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("Decoding \(T.self) from \(path) failed:", error)
            #endif
            throw APIError(status: 0, message: "The server sent a response the app didn't understand.")
        }
    }

    private func perform(
        _ path: String,
        method: String,
        query: [String: String],
        body: (any Encodable)?,
        authenticated: Bool,
        allowReauth: Bool,
        apiKeyOverride: String? = nil
    ) async throws -> Data {
        var url = baseURL.appendingPathComponent("api/v1").appendingPathComponent(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = query
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(Self.percentEncode($0.value))" }
                .joined(separator: "&")
            url = components.url ?? url
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key = apiKeyOverride ?? (authenticated ? apiKey : nil) {
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        } else if authenticated, let sessionCookie {
            request.setValue("connect.sid=\(sessionCookie)", forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, message: "No response from the server.")
        }
        captureCookie(from: http)

        if authenticated, allowReauth, credentials?.usesSession == true,
           http.statusCode == 401 || http.statusCode == 403 {
            try await reauthenticate()
            return try await perform(path, method: method, query: query, body: body,
                                     authenticated: authenticated, allowReauth: false)
        }

        guard (200..<300).contains(http.statusCode) else {
            let fallback = HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
            throw APIError(status: http.statusCode, message: Self.message(from: data) ?? fallback)
        }
        return data
    }

    /// Coalesces concurrent re-logins (e.g. a whole row of posters failing at once) into one.
    private func reauthenticate() async throws {
        if let reauthTask { return try await reauthTask.value }
        guard let credentials else { throw APIError(status: 401, message: "Please sign in again.") }
        let task = Task { try await self.login(with: credentials); return () }
        reauthTask = task
        defer { reauthTask = nil }
        try await task.value
    }

    private func captureCookie(from response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if let sid = cookies.first(where: { $0.name == "connect.sid" }) {
            updateCookie(sid.value)
        }
    }

    private func updateCookie(_ value: String?) {
        guard value != sessionCookie else { return }
        sessionCookie = value
        onSessionChange(value)
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Seerr rejects search queries with unencoded reserved characters, so encode strictly.
    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func message(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            let message: String?
            let error: String?
        }
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else { return nil }
        return body.message ?? body.error
    }
}
