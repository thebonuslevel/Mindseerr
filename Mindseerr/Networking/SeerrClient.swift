import Foundation

struct APIError: LocalizedError, Sendable {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

enum DiscoverSection: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded, trending, popularMovies, upcomingMovies, popularTV, upcomingTV

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: return String(localized: "Recently Added")
        case .trending: return String(localized: "Trending")
        case .popularMovies: return String(localized: "Popular Movies")
        case .upcomingMovies: return String(localized: "Upcoming Movies")
        case .popularTV: return String(localized: "Popular Series")
        case .upcomingTV: return String(localized: "Upcoming Series")
        }
    }

    var path: String {
        switch self {
        case .recentlyAdded: return "media"   // not a discover list: see SeerrClient.recentlyAdded
        case .trending: return "discover/trending"
        case .popularMovies: return "discover/movies"
        case .upcomingMovies: return "discover/movies/upcoming"
        case .popularTV: return "discover/tv"
        case .upcomingTV: return "discover/tv/upcoming"
        }
    }
}

/// Follows a redirect only when it stays on the same server (or upgrades it from http to https). The session cookie
/// and API key are added to each request by hand, and URLSession would carry them along to wherever a redirect
/// pointed, so anything else is refused.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url,
              from.host?.lowercased() == to.host?.lowercased() else { return completionHandler(nil) }
        let upgrade = from.scheme == "http" && to.scheme == "https"
        let sameOrigin = from.scheme == to.scheme && effectivePort(from) == effectivePort(to)
        completionHandler(sameOrigin || upgrade ? request : nil)
    }

    private func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil)
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
        timeout: TimeInterval = 20,
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
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config, delegate: SameOriginRedirects(), delegateQueue: nil)
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
        if section == .recentlyAdded { return try await recentlyAdded(page: page) }
        return try await send(section.path, query: ["page": "\(page)"])
    }

    /// The genres Seerr offers for movies or series.
    func genres(for type: MediaType) async throws -> [Genre] {
        try await send(type == .tv ? "discover/genreslider/tv" : "discover/genreslider/movie")
    }

    /// The logo of a studio or network (a TMDB image path), or nil when Seerr has none or doesn't offer the lookup.
    func companyLogo(for target: BrowseTarget) async -> String? {
        struct Company: Decodable { let logoPath: String? }
        let path = target.filter == .network ? "network/\(target.id)" : "studio/\(target.id)"
        let company: Company? = try? await send(path)
        return company?.logoPath
    }

    /// One page of the titles in a genre, studio or network, in the chosen order. Newest leaves out what isn't out
    /// yet, and Top Rated what hardly anyone has rated, so neither starts with noise.
    func browse(_ target: BrowseTarget, sort: BrowseSort, page: Int) async throws -> PagedResponse<MediaResult> {
        var query = ["page": "\(page)", "sortBy": sort.sortBy(for: target.type)]
        query[target.filter.rawValue] = "\(target.id)"
        switch sort {
        case .popular: break
        case .topRated: query["voteCountGte"] = "200"
        case .newest:
            let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
            query[target.type == .tv ? "firstAirDateLte" : "primaryReleaseDateLte"] = String(today)
        }
        return try await send(target.type == .tv ? "discover/tv" : "discover/movies", query: query)
    }

    /// The newest titles on the server (available or partly available), newest first. Seerr lists them as bare
    /// media records, so each one's details are looked up (and cached) to get its title and poster.
    func recentlyAdded(page: Int) async throws -> PagedResponse<MediaResult> {
        struct Item: Decodable { let tmdbId: Int?; let mediaType: MediaType? }
        struct Page: Decodable {
            struct Info: Decodable { let pages: Int }
            let pageInfo: Info
            let results: [Item]
        }
        let take = 20
        let list: Page = try await send("media", query: ["filter": "allavailable", "sort": "added",
                                                        "take": "\(take)", "skip": "\((page - 1) * take)"])
        let routes = list.results.compactMap { item -> MediaRoute? in
            guard let id = item.tmdbId, let type = item.mediaType, type == .movie || type == .tv else { return nil }
            return MediaRoute(type: type, tmdbId: id)
        }
        let api = self
        let results = await boundedMap(routes, limit: 6) { route -> MediaResult? in
            guard let detail = try? await api.detail(for: route) else { return nil }
            return MediaResult.make(from: detail, route: route)
        }
        return PagedResponse(page: page, totalPages: max(list.pageInfo.pages, 1), totalResults: results.count, results: results.compactMap { $0 })
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

    func season(_ number: Int, ofSeries tmdbId: Int) async throws -> SeasonDetail {
        try await send("tv/\(tmdbId)/season/\(number)")
    }

    func person(_ id: Int) async throws -> PersonDetail {
        try await send("person/\(id)")
    }

    func credits(forPerson id: Int) async throws -> PersonCredits {
        try await send("person/\(id)/combined_credits")
    }

    /// The Rotten Tomatoes scores for a title, or nil when Seerr has none (or can't look them up).
    func rottenTomatoes(for route: MediaRoute) async -> RottenTomatoesRating? {
        let path = (route.type == .tv ? "tv/" : "movie/") + "\(route.tmdbId)/ratings"
        guard let rating: RottenTomatoesRating = try? await send(path), rating.hasScore else { return nil }
        return rating
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

    /// What the signed-in user may still request. Throws if Seerr doesn't offer it (older versions), which callers ignore.
    func quota(forUser userId: Int) async throws -> RequestQuota {
        try await send("user/\(userId)/quota")
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
            case .pending: return String(localized: "Pending")
            case .processing: return String(localized: "Processing")
            case .failed: return String(localized: "Failed")
            case .available: return String(localized: "Available")
            case .all: return String(localized: "All")
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
            throw APIError(status: 0, message: String(localized: "The server sent a response the app didn't understand."))
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
            throw APIError(status: 0, message: String(localized: "No response from the server."))
        }
        captureCookie(from: http)

        if authenticated, allowReauth, credentials?.usesSession == true,
           http.statusCode == 401 || http.statusCode == 403 {
            try await reauthenticate()
            return try await perform(path, method: method, query: query, body: body,
                                     authenticated: authenticated, allowReauth: false)
        }

        if (300..<400).contains(http.statusCode) {
            throw APIError(status: http.statusCode,
                           message: String(localized: "The server redirected to a different address. Enter the address it redirects to instead."))
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
        guard let credentials else { throw APIError(status: 401, message: String(localized: "Please sign in again.")) }
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
