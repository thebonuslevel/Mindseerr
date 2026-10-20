import Foundation
import Observation

/// A download that just finished, shown as a banner.
struct FinishedDownload: Identifiable, Sendable {
    let id = UUID()
    let title: String
    /// "Season 2, Episode 5" for a series; nil for a movie.
    let episodeLabel: String?
    let route: MediaRoute?
}

/// Whether finished downloads pop up a banner. On by default; the switch is in Settings.
enum DownloadNotifications {
    private static let key = "notifications.downloadFinished"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// The connected Sonarr/Radarr/torrent-client servers and what they're downloading, shared by the whole app so
/// posters, detail pages and the Admin tab all show the same progress.
@MainActor
@Observable
final class DownloadMonitor {
    private(set) var services: [ArrService] = DownloadMonitor.initialServices()
    private(set) var downloads: [ArrDownload] = []
    /// Why a service couldn't be read on the last refresh.
    private(set) var errors: [UUID: String] = [:]
    /// False until the first refresh after the services changed.
    private(set) var loaded = false
    /// Which qBittorrent server holds each torrent (by lowercased info hash), so a download can be paused or resumed.
    private(set) var torrentOwners: [String: UUID] = [:]
    /// The banner on screen for a download that just finished, if any. Others wait their turn.
    private(set) var banner: FinishedDownload?
    @ObservationIgnored private var bannerQueue: [FinishedDownload] = []
    /// Downloads the user cancelled, so their disappearing isn't announced as a finish.
    @ObservationIgnored private var userRemoved: Set<String> = []

    @ObservationIgnored private var torrentClients: [UUID: TorrentClient] = [:]
    /// Used to work out which Seerr title a qBittorrent-only download is for (see `identity(of:)`).
    @ObservationIgnored private var seerr: SeerrClient?
    /// Which title each torrent turned out to be, by lowercased info hash; nil when nothing matched.
    @ObservationIgnored private var identities: [String: TorrentIdentity?] = [:]

    private struct TorrentIdentity: Sendable {
        let tmdbId: Int
        let type: MediaType
        let title: String
    }

    private let refreshInterval: Duration = .seconds(10)

    /// Stands in for Seerr in the downloads it reports itself (see `ArrClient.downloads(fromSeerr:)`).
    nonisolated static let seerrServiceID = UUID(uuidString: "5EE22000-0000-4000-8000-000000000001")!
    /// Whether this download came through Seerr, which can show it but not control it.
    func isFromSeerr(_ download: ArrDownload) -> Bool { download.serviceID == Self.seerrServiceID }

    // MARK: Services

    private static func initialServices() -> [ArrService] {
        #if DEBUG
        if let demo = DemoMode.arrServices { return demo }
        #endif
        return ArrServiceStore.load()
    }

    func add(_ service: ArrService) {
        services.append(service)
        save()
    }

    func remove(_ service: ArrService) {
        services.removeAll { $0.id == service.id }
        errors[service.id] = nil
        torrentClients[service.id] = nil
        torrentOwners = torrentOwners.filter { $0.value != service.id }
        save()
    }

    private func save() {
        #if DEBUG
        if DemoMode.arrServices != nil { return } // demo services are never written to the Keychain
        #endif
        ArrServiceStore.save(services)
    }

    // MARK: Lookups

    /// Every queued download for one movie or series. Sonarr may list several episodes separately.
    func downloads(for type: MediaType, tmdbId: Int?, tvdbId: Int?) -> [ArrDownload] {
        downloads.filter { $0.matches(type: type, tmdbId: tmdbId, tvdbId: tvdbId) }
    }

    /// Combined progress of a title's downloads (0...1), or nil when nothing is downloading.
    func progress(for type: MediaType, tmdbId: Int?, tvdbId: Int?) -> Double? {
        let items = downloads(for: type, tmdbId: tmdbId, tvdbId: tvdbId)
        guard !items.isEmpty else { return nil }
        return items.map(\.progress).reduce(0, +) / Double(items.count)
    }

    // MARK: Controls

    /// Whether Mindseerr can pause and resume this download: its torrent is on a connected qBittorrent server.
    func canPause(_ download: ArrDownload) -> Bool {
        guard let hash = download.downloadId?.lowercased(), torrentOwners[hash] != nil else { return false }
        switch download.phase {
        case .downloading, .queued, .paused, .delayed, .warning: return true
        case .importing, .failed, .other: return false
        }
    }

    /// Whether any of these downloads can be paused or resumed.
    func canPause(_ downloads: [ArrDownload]) -> Bool {
        downloads.contains { canPause($0) }
    }

    /// Pauses running downloads, or resumes them when every one is already paused.
    func togglePause(_ downloads: [ArrDownload]) async throws {
        let controllable = downloads.filter { canPause($0) }
        let resume = controllable.allSatisfy { $0.phase == .paused }
        // A season pack is several entries with one torrent: only touch each torrent once.
        var done: Set<String> = []
        for download in controllable {
            guard let hash = download.downloadId?.lowercased(), done.insert(hash).inserted,
                  let owner = torrentOwners[hash], let client = torrentClients[owner] else { continue }
            if resume {
                try await client.resume(hash: hash)
            } else if download.phase != .paused {
                try await client.pause(hash: hash)
            }
        }
        await refresh()
    }

    func togglePause(_ download: ArrDownload) async throws {
        try await togglePause([download])
    }

    /// Whether any of these downloads can be cancelled from here: it's in a service this Apple TV is connected to.
    func canCancel(_ downloads: [ArrDownload]) -> Bool {
        downloads.contains { download in services.contains { $0.id == download.serviceID } }
    }

    /// Whether any of these downloads is in a Sonarr/Radarr queue, the only place a release can be blocklisted.
    func canBlocklist(_ downloads: [ArrDownload]) -> Bool {
        downloads.contains { download in
            services.first(where: { $0.id == download.serviceID }).map { !$0.kind.isDownloadClient } ?? false
        }
    }

    /// Cancels downloads: removes them from the Sonarr/Radarr queue and deletes them from the download client.
    /// With `blocklist`, releases in a Sonarr/Radarr queue are also blocklisted (a torrent client has no blocklist).
    func cancel(_ downloads: [ArrDownload], blocklist: Bool = false) async throws {
        userRemoved.formUnion(downloads.map(\.id))
        for download in downloads {
            guard let service = services.first(where: { $0.id == download.serviceID }) else { continue }
            if service.kind.isDownloadClient {
                // A download read straight from a torrent client has no queue entry: remove the torrent itself.
                if let hash = download.downloadId, let client = torrentClients[service.id] { try await client.delete(hash: hash) }
            } else {
                try await ArrClient.cancel(download, on: service, blocklist: blocklist)
            }
        }
        await refresh()
    }

    func cancel(_ download: ArrDownload, blocklist: Bool = false) async throws {
        try await cancel([download], blocklist: blocklist)
    }

    // MARK: Polling


    /// Refreshes the queues until cancelled. Run it with `.task(id: services)` so it restarts when
    /// services are added or removed. `api` lets qBittorrent downloads be matched to Seerr titles when
    /// there's no Sonarr or Radarr to say which title they are.
    func run(api: SeerrClient? = nil) async {
        seerr = api
        loaded = false
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: refreshInterval)
        }
    }

    /// Reads every service's queue at once. A service that can't be reached reports its error
    /// without hiding the others' downloads.
    func refresh() async {
        let current = services.filter { !$0.kind.isDownloadClient }
        let torrentServices = services.filter { $0.kind.isDownloadClient }
        async let torrents = readTorrents(torrentServices)
        let results = await withTaskGroup(of: (UUID, Result<[ArrDownload], Error>).self) { group in
            for service in current {
                group.addTask {
                    do { return (service.id, .success(try await ArrClient.downloads(from: service))) }
                    catch { return (service.id, .failure(error)) }
                }
            }
            var collected: [UUID: Result<[ArrDownload], Error>] = [:]
            for await (id, result) in group { collected[id] = result }
            return collected
        }
        guard !Task.isCancelled else { return }

        var fresh: [ArrDownload] = []
        var failures: [UUID: String] = [:]
        for service in current {   // keep the services' order
            switch results[service.id] {
            case .success(let items): fresh += items
            case .failure(let error): failures[service.id] = AppState.friendly(error)
            case nil: break
            }
        }
        let (owners, torrentFailures, listed) = await torrents

        // Torrents Sonarr/Radarr already report are shown through them. Any other unfinished torrent is
        // shown straight from qBittorrent, matched to a Seerr title by its release name.
        let known = Set(fresh.compactMap { $0.downloadId?.lowercased() })
        let extra = listed.filter { !$0.torrent.isFinished && !known.contains($0.torrent.hash.lowercased()) }
        await identify(extra.map(\.torrent))
        fresh += extra.map { makeDownload($0.torrent, on: $0.service) }

        // Whatever Seerr reports for titles no connected service covers, so everyone sees progress.
        var seerrReachable = true
        if let seerr {
            do {
                let page = try await seerr.allRequests(filter: .processing, skip: 0, take: 100)
                let feed = ArrClient.downloads(fromSeerr: page.results)
                fresh += feed.filter { item in
                    !fresh.contains { $0.matches(type: item.mediaType, tmdbId: item.tmdbId, tvdbId: item.tvdbId) }
                }
            } catch {
                seerrReachable = false
            }
        }

        var unreachable = Set(failures.keys).union(torrentFailures.keys)
        if !seerrReachable { unreachable.insert(Self.seerrServiceID) }
        // What was last seen: in memory while the app has been running, or what was saved when it was last open.
        // The latter is how a download that finished while the app was closed gets announced on reopening.
        let previous = loaded ? downloads.map(SavedDownload.init) : SavedDownload.load()
        announceFinished(old: previous, new: fresh, unreachable: unreachable)
        // Keep what an unreachable service held, so its downloads aren't judged finished next time.
        let kept = previous.filter { unreachable.contains($0.serviceID) }
        SavedDownload.save(fresh.map(SavedDownload.init) + kept)
        downloads = fresh
        errors = failures.merging(torrentFailures) { first, _ in first }
        torrentOwners = owners
        loaded = true
    }

    /// Reads which torrents each qBittorrent server holds. One that can't be reached reports its error.
    private func readTorrents(_ services: [ArrService]) async
        -> ([String: UUID], [UUID: String], [(service: ArrService, torrent: TorrentInfo)]) {
        var owners: [String: UUID] = [:]
        var failures: [UUID: String] = [:]
        var listed: [(service: ArrService, torrent: TorrentInfo)] = []
        for service in services {
            let client = torrentClients[service.id] ?? TorrentClients.make(for: service)
            torrentClients[service.id] = client
            do {
                for torrent in try await client.torrents() {
                    owners[torrent.hash.lowercased()] = service.id
                    listed.append((service, torrent))
                }
            } catch {
                failures[service.id] = AppState.friendly(error)
            }
        }
        return (owners, failures, listed)
    }

    // MARK: Finished downloads

    /// Queues a banner for each download that has left the queues since the last refresh and was nearly done
    /// (or importing) when last seen: that's a finish, where a cancelled, failed or blocklisted one isn't.
    /// A service that couldn't be read is skipped, so a network blip doesn't announce everything it held.
    private func announceFinished(old: [SavedDownload], new: [ArrDownload], unreachable: Set<UUID>) {
        let stillThere = Set(new.map(\.id))
        let live = Set(services.map(\.id)).union([Self.seerrServiceID])
        var announced: Set<String> = []
        var finished: [FinishedDownload] = []
        // A removed service's downloads vanish too, which isn't a finish.
        for download in old where !stillThere.contains(download.id) && !unreachable.contains(download.serviceID) && live.contains(download.serviceID) {
            if userRemoved.remove(download.id) != nil { continue }
            guard download.progress >= 0.9 || download.importing, let tmdbId = download.tmdbId else { continue }
            // One banner per title and episode, even if two services held it.
            guard announced.insert("\(tmdbId)-\(download.episodeLabel ?? "")").inserted else { continue }
            finished.append(FinishedDownload(title: download.title, episodeLabel: download.episodeLabel,
                                             route: MediaRoute(type: download.type, tmdbId: tmdbId)))
        }
        guard DownloadNotifications.isEnabled, !finished.isEmpty else { return }
        // After a long time away there can be many: show a few, then one banner for the rest.
        let shown = 4
        bannerQueue += finished.prefix(shown)
        if finished.count > shown {
            let more = finished.count - shown
            bannerQueue.append(FinishedDownload(title: more == 1 ? "1 more download" : "\(more) more downloads",
                                                episodeLabel: nil, route: nil))
        }
        if banner == nil { dismissBanner() }
    }

    /// Takes the banner off the screen and shows the next waiting one.
    func dismissBanner() {
        banner = bannerQueue.isEmpty ? nil : bannerQueue.removeFirst()
    }

    // MARK: qBittorrent-only downloads

    private func makeDownload(_ torrent: TorrentInfo, on service: ArrService) -> ArrDownload {
        let parsed = ReleaseName.parse(torrent.name)
        let identity = identities[torrent.hash.lowercased()] ?? nil
        let type: MediaType = identity?.type ?? (parsed.isSeries ? .tv : .movie)
        return ArrDownload(
            id: "\(service.id.uuidString)-\(torrent.hash.lowercased())",
            serviceID: service.id,
            serviceName: service.name,
            kind: service.kind,
            downloadId: torrent.hash,
            queueIds: [],
            title: identity?.title ?? parsed.title,
            episodeLabel: type == .tv ? parsed.episodeLabel : nil,
            tmdbId: identity?.tmdbId,
            tvdbId: nil,
            progress: min(max(torrent.progress, 0), 1),
            secondsLeft: torrent.secondsLeft,
            phase: torrent.phase,
            message: torrent.phase.isProblem ? "\(service.kind.name) reports “\(torrent.state)”." : nil,
            resolvedType: type
        )
    }

    /// Looks up the Seerr title for torrents not seen before. A torrent that matches nothing is remembered
    /// as unmatched, so it isn't searched for again on every refresh.
    private func identify(_ torrents: [TorrentInfo]) async {
        guard let seerr else { return }
        let fresh = torrents.filter { identities[$0.hash.lowercased()] == nil }
        guard !fresh.isEmpty else { return }
        let found = await boundedMap(fresh, limit: 4) { torrent in
            (torrent.hash.lowercased(), await Self.identity(of: torrent.name, using: seerr))
        }
        for (hash, identity) in found { identities[hash] = .some(identity) }
    }

    /// Searches Seerr for the title named by a release name: the result whose title matches exactly,
    /// preferring the expected kind (series for S01E02-style names, otherwise movies) and the same year.
    nonisolated private static func identity(of name: String, using seerr: SeerrClient) async -> TorrentIdentity? {
        let parsed = ReleaseName.parse(name)
        guard let results = try? await seerr.search(parsed.title).results else { return nil }
        func normalized(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = normalized(parsed.title)
        let candidates = results.filter { $0.route != nil && normalized($0.displayTitle) == wanted }
        let best = candidates.max { score($0, parsed) < score($1, parsed) }
        guard let best else { return nil }
        return TorrentIdentity(tmdbId: best.id, type: best.type, title: best.displayTitle)
    }

    nonisolated private static func score(_ result: MediaResult, _ parsed: ReleaseName) -> Int {
        var points = 0
        if (result.type == .tv) == parsed.isSeries { points += 2 }
        if let year = parsed.year, result.year == String(year) { points += 1 }
        return points
    }
}

/// What the app remembers about a download between launches, to tell which finished while it was closed.
private struct SavedDownload: Codable {
    let id: String
    let serviceID: UUID
    let title: String
    let episodeLabel: String?
    let tmdbId: Int?
    let type: MediaType
    let progress: Double
    let importing: Bool

    init(_ download: ArrDownload) {
        id = download.id
        serviceID = download.serviceID
        title = download.title
        episodeLabel = download.episodeLabel
        tmdbId = download.tmdbId
        type = download.mediaType
        progress = download.progress
        importing = download.phase == .importing
    }

    private static let key = "downloads.lastSeen"

    static func load() -> [SavedDownload] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedDownload].self, from: data)) ?? []
    }

    static func save(_ downloads: [SavedDownload]) {
        if let data = try? JSONEncoder().encode(downloads) { UserDefaults.standard.set(data, forKey: key) }
    }
}
