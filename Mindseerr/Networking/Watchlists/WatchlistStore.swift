import Foundation
import Observation

/// Holds the connected watchlists, the imported titles and their status on the Seerr server.
@MainActor
@Observable
final class WatchlistStore {
    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    var source: WatchlistSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: Keys.source) }
    }
    private(set) var letterboxdUser: String
    private(set) var traktSignedIn = false
    private(set) var traktName: String?
    private(set) var tmdbSignedIn = false
    private(set) var tmdbName: String?
    private(set) var tvdbSignedIn = false
    private(set) var entries: [WatchlistSource: [WatchlistEntry]] = [:]
    private(set) var items: [String: WatchlistItem] = [:]
    private(set) var phase: [WatchlistSource: Phase] = [:]
    private(set) var requestProgress: String?

    let trakt = TraktClient()
    let tmdb = TMDBAccountClient()
    let tvdb = TVDBClient()

    /// What a first import runs against before it becomes the connection, so the screen doesn't
    /// switch to "connected" until the import has worked.
    @ObservationIgnored private var letterboxdCandidate: String?

    private enum Keys {
        static let source = "watchlist.source"
        static let letterboxd = "watchlist.letterboxdUser"
        static func entries(_ s: WatchlistSource) -> String { "watchlist.entries.\(s.rawValue)" }
        /// Left over from the removed IMDb source.
        static let legacyIMDb = ["watchlist.imdbUserID", "watchlist.imdbLists", "watchlist.entries.imdb"]
    }

    init() {
        let defaults = UserDefaults.standard
        Keys.legacyIMDb.forEach(defaults.removeObject(forKey:))
        source = WatchlistSource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .trakt
        letterboxdUser = defaults.string(forKey: Keys.letterboxd) ?? ""
        for s in WatchlistSource.allCases {
            if let data = defaults.data(forKey: Keys.entries(s)),
               let saved = try? JSONDecoder().decode([WatchlistEntry].self, from: data) {
                entries[s] = saved
            }
        }
    }

    // MARK: - Reading state

    func isConnected(_ s: WatchlistSource) -> Bool {
        switch s {
        case .trakt: return traktSignedIn
        case .letterboxd: return !letterboxdUser.isEmpty
        case .tmdb: return tmdbSignedIn
        case .tvdb: return tvdbSignedIn
        }
    }

    func isBusy(_ s: WatchlistSource) -> Bool {
        if case .working = phase[s] { return true }
        return requestProgress != nil
    }

    func visibleItems(_ s: WatchlistSource, missingOnly: Bool) -> [WatchlistItem] {
        let all = (entries[s] ?? []).map { items[$0.id] ?? .placeholder($0) }
        return missingOnly ? all.filter(\.canRequest) : all
    }

    func missingCount(_ s: WatchlistSource) -> Int {
        visibleItems(s, missingOnly: true).count
    }

    func accountLine(_ s: WatchlistSource) -> String {
        switch s {
        case .trakt: return "Trakt · \(traktName ?? "signed in")"
        case .letterboxd: return "Letterboxd · \(letterboxdUser)"
        case .tmdb: return "TMDB · \(tmdbName ?? "signed in")"
        case .tvdb: return "TheTVDB · favorites"
        }
    }

    func summaryLine(_ s: WatchlistSource) -> String {
        let all = visibleItems(s, missingOnly: false)
        guard !all.isEmpty else { return "No titles imported yet." }
        let available = all.filter { $0.status == .available }.count
        let requested = all.filter { $0.status == .requested }.count
        let missing = all.filter(\.canRequest).count
        let unmatched = all.filter { $0.status == .notFound }.count
        var parts = ["\(all.count) titles", "\(available) available", "\(requested) requested", "\(missing) not on server"]
        if unmatched > 0 { parts.append("\(unmatched) couldn't be matched") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Connecting

    func load(api: SeerrClient) async {
        #if DEBUG
        // Demo mode shows a made-up Trakt watchlist and never touches the real accounts.
        if let demo = DemoMode.watchlist {
            traktSignedIn = true
            traktName = "Demo"
            entries[.trakt] = demo
            await resolve(.trakt, api: api)
            return
        }
        #endif
        traktSignedIn = await trakt.isSignedIn
        if traktSignedIn, traktName == nil { traktName = try? await trakt.displayName() }
        tmdbSignedIn = await tmdb.isSignedIn
        if tmdbSignedIn, tmdbName == nil { tmdbName = await tmdb.displayName() }
        tvdbSignedIn = await tvdb.isSignedIn
        await resolve(source, api: api)
    }

    func traktDidSignIn(api: SeerrClient) async {
        traktSignedIn = await trakt.isSignedIn
        traktName = try? await trakt.displayName()
        source = .trakt
        await refresh(.trakt, api: api)
    }

    func tmdbDidSignIn(api: SeerrClient) async {
        tmdbSignedIn = await tmdb.isSignedIn
        tmdbName = await tmdb.displayName()
        source = .tmdb
        await refresh(.tmdb, api: api)
    }

    /// Connects Letterboxd or TheTVDB. Returns an error message if the input or the import failed.
    func connect(_ s: WatchlistSource, input: String, api: SeerrClient) async -> String? {
        switch s {
        case .letterboxd:
            guard let name = LetterboxdImporter.username(from: input) else {
                return "Enter your Letterboxd username, like “davidehrlich”."
            }
            letterboxdCandidate = name
            defer { letterboxdCandidate = nil }
            guard await refresh(.letterboxd, api: api) else {
                let message = failureMessage(.letterboxd)
                phase[.letterboxd] = .idle
                return message
            }
            setLetterboxdUser(name)
            return nil


        case .tvdb:
            let pin = input.trimmed
            guard !pin.isEmpty else { return "Enter your TheTVDB PIN." }
            phase[.tvdb] = .working("Signing in to TheTVDB…")
            do {
                try await tvdb.signIn(pin: pin)
            } catch {
                phase[.tvdb] = .idle
                return AppState.friendly(error)
            }
            phase[.tvdb] = .idle // refresh() won't start while a phase is still working
            // Not "connected" until the first import has worked, like Letterboxd.
            guard await refresh(.tvdb, api: api) else {
                let message = failureMessage(.tvdb)
                await tvdb.signOut()
                phase[.tvdb] = .idle
                return message
            }
            tvdbSignedIn = true
            source = .tvdb
            return nil

        case .trakt, .tmdb:
            return nil
        }
    }

    func disconnect
(_ s: WatchlistSource) async {
        switch s {
        case .trakt:
            await trakt.signOut()
            traktSignedIn = false
            traktName = nil
        case .tmdb:
            await tmdb.signOut()
            tmdbSignedIn = false
            tmdbName = nil
        case .tvdb:
            await tvdb.signOut()
            tvdbSignedIn = false
        case .letterboxd:
            setLetterboxdUser("")
        }
        for entry in entries[s] ?? [] { items[entry.id] = nil }
        entries[s] = nil
        phase[s] = .idle
        UserDefaults.standard.removeObject(forKey: Keys.entries(s))
    }

    private func failureMessage(_ s: WatchlistSource) -> String {
        if case .failed(let message) = phase[s] { return message }
        return "The import didn't finish. Try again."
    }

    private func setLetterboxdUser(_ value: String) {
        letterboxdUser = value
        UserDefaults.standard.set(value, forKey: Keys.letterboxd)
    }

    // MARK: - Importing

    /// Imports the watchlist again. Returns false if nothing could be imported.
    @discardableResult
    func refresh(_ s: WatchlistSource, api: SeerrClient) async -> Bool {
        if case .working = phase[s] { return false }
        phase[s] = .working("Starting…")
        let report: @Sendable (String) async -> Void = { message in await self.setWorking(s, message) }
        do {
            let fetched: [WatchlistEntry]
            switch s {
            case .trakt:
                await report("Reading your Trakt watchlist…")
                fetched = try await trakt.watchlist()
                if !(await trakt.isSignedIn) { traktSignedIn = false }
            case .tmdb:
                await report("Reading your TMDB watchlist…")
                fetched = try await tmdb.watchlist()
                if !(await tmdb.isSignedIn) { tmdbSignedIn = false }
            case .tvdb:
                await report("Reading your TheTVDB favorites…")
                fetched = try await tvdb.watchlist(progress: report)
            case .letterboxd:
                fetched = try await LetterboxdImporter.fetchWatchlist(username: letterboxdCandidate ?? letterboxdUser,
                                                                      progress: report)
            }
            entries[s] = fetched
            if let data = try? JSONEncoder().encode(fetched) {
                UserDefaults.standard.set(data, forKey: Keys.entries(s))
            }
            await resolve(s, api: api, report: report)
            phase[s] = .idle
            return true
        } catch is CancellationError {
            phase[s] = .idle
            return false
        } catch {
            if s == .trakt { traktSignedIn = await trakt.isSignedIn }
            if s == .tmdb { tmdbSignedIn = await tmdb.isSignedIn }
            phase[s] = .failed(AppState.friendly(error))
            return false
        }
    }

    private func setWorking(_ s: WatchlistSource, _ message: String) {
        if case .working = phase[s] { phase[s] = .working(message) }
    }

    /// Matches entries to Seerr and reads their status. Seerr details are cached, so after the
    /// first run this only re-checks titles that were requested since.
    func resolve(_ s: WatchlistSource, api: SeerrClient, report: (@Sendable (String) async -> Void)? = nil) async {
        let list = entries[s] ?? []
        guard !list.isEmpty else { return }
        await report?("Checking \(list.count) titles on your server…")
        let work = list.map { (entry: $0, known: items[$0.id]?.route) }
        let resolved = await boundedMap(work, limit: 6) { job in
            await Self.resolveItem(job.entry, knownRoute: job.known, api: api)
        }
        for item in resolved { items[item.id] = item }
    }

    nonisolated private static func resolveItem(_ entry: WatchlistEntry, knownRoute: MediaRoute?,
                                                api: SeerrClient) async -> WatchlistItem {
        var route = knownRoute
        if route == nil, let tmdb = entry.tmdbId, let kind = entry.kind, kind == .movie || kind == .tv {
            route = MediaRoute(type: kind, tmdbId: tmdb)
        }
        if route == nil, let imdb = entry.imdbId,
           let results = try? await api.search("imdb:\(imdb)").results {
            let matches = results.compactMap(\.route)
            route = matches.first { $0.type == entry.kind } ?? matches.first
        }
        guard let route else { return .placeholder(entry, status: .notFound) }
        guard let detail = try? await api.detail(for: route) else {
            return .placeholder(entry, status: .unchecked, route: route)
        }
        let status: WatchlistStatus
        switch RequestAvailability(detail: detail, type: route.type) {
        case .requestable: status = .missing
        case .partiallyRequestable: status = .partial
        case .requested: status = .requested
        case .available: status = .available
        }
        return WatchlistItem(entry: entry, route: route, title: detail.displayTitle, year: detail.year,
                             posterURL: TMDBImage.url(detail.posterPath, size: .poster), status: status)
    }

    // MARK: - Requesting

    struct RequestSummary {
        let sent: Int
        let failed: Int
        let firstError: String?
    }

    /// What the user picked in the request sheet: the seasons wanted for each series (by item id), and the
    /// ids of titles to leave out. Nothing here means "request everything that's missing".
    struct RequestChoices {
        var seasons: [String: [Int]] = [:]
        var skipped: Set<String> = []
    }

    func requestAllMissing(_ s: WatchlistSource, api: SeerrClient, choices: RequestChoices = RequestChoices()) async -> RequestSummary {
        let targets = visibleItems(s, missingOnly: true).filter { !choices.skipped.contains($0.id) }
        var sent = 0, failed = 0
        var firstError: String?
        for (index, item) in targets.enumerated() {
            guard let route = item.route else { continue }
            requestProgress = "Requesting \(index + 1) of \(targets.count): \(item.title)"
            do {
                if route.type == .tv {
                    let detail = try await api.detail(for: route, useCache: false)
                    // The seasons the user picked, limited to ones that can still be requested.
                    let open = detail.requestableSeasonNumbers
                    let seasons = choices.seasons[item.id].map { picked in open.filter(picked.contains) } ?? open
                    guard !seasons.isEmpty else { continue }
                    _ = try await api.request(route, seasons: seasons)
                } else {
                    _ = try await api.request(route)
                }
                sent += 1
            } catch {
                failed += 1
                if firstError == nil { firstError = AppState.friendly(error) }
            }
        }
        requestProgress = nil
        await resolve(s, api: api)
        return RequestSummary(sent: sent, failed: failed, firstError: firstError)
    }
}
