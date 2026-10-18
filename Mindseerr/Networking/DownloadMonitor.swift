import Foundation
import Observation

/// The connected Sonarr/Radarr/qBittorrent servers and what they're downloading, shared by the whole app so
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

    @ObservationIgnored private var qbitClients: [UUID: QBittorrentClient] = [:]
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
        qbitClients[service.id] = nil
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
                  let owner = torrentOwners[hash], let client = qbitClients[owner] else { continue }
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

    /// Cancels downloads: removes them from the Sonarr/Radarr queue and deletes them from the download client.
    func cancel(_ downloads: [ArrDownload]) async throws {
        for download in downloads {
            guard let service = services.first(where: { $0.id == download.serviceID }) else { continue }
            if service.kind == .qbittorrent {
                // A download read straight from qBittorrent has no queue entry: remove the torrent itself.
                if let hash = download.downloadId, let client = qbitClients[service.id] { try await client.delete(hash: hash) }
            } else {
                try await ArrClient.cancel(download, on: service)
            }
        }
        await refresh()
    }

    func cancel(_ download: ArrDownload) async throws {
        try await cancel([download])
    }

    // MARK: Polling


    /// Refreshes the queues until cancelled. Run it with `.task(id: services)` so it restarts when
    /// services are added or removed. `api` lets qBittorrent downloads be matched to Seerr titles when
    /// there's no Sonarr or Radarr to say which title they are.
    func run(api: SeerrClient? = nil) async {
        seerr = api
        loaded = false
        guard !services.isEmpty else {
            downloads = []
            errors = [:]
            torrentOwners = [:]
            return
        }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: refreshInterval)
        }
    }

    /// Reads every service's queue at once. A service that can't be reached reports its error
    /// without hiding the others' downloads.
    func refresh() async {
        let current = services.filter { $0.kind != .qbittorrent }
        let torrentServices = services.filter { $0.kind == .qbittorrent }
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

        downloads = fresh
        errors = failures.merging(torrentFailures) { first, _ in first }
        torrentOwners = owners
        loaded = true
    }

    /// Reads which torrents each qBittorrent server holds. One that can't be reached reports its error.
    private func readTorrents(_ services: [ArrService]) async
        -> ([String: UUID], [UUID: String], [(service: ArrService, torrent: QBitTorrent)]) {
        var owners: [String: UUID] = [:]
        var failures: [UUID: String] = [:]
        var listed: [(service: ArrService, torrent: QBitTorrent)] = []
        for service in services {
            let client = qbitClients[service.id] ?? QBittorrentClient(service: service)
            qbitClients[service.id] = client
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

    // MARK: qBittorrent-only downloads

    private func makeDownload(_ torrent: QBitTorrent, on service: ArrService) -> ArrDownload {
        let parsed = ReleaseName.parse(torrent.name)
        let identity = identities[torrent.hash.lowercased()] ?? nil
        let type: MediaType = identity?.type ?? (parsed.isSeries ? .tv : .movie)
        return ArrDownload(
            id: "\(service.id.uuidString)-\(torrent.hash.lowercased())",
            serviceID: service.id,
            serviceName: service.name,
            kind: .qbittorrent,
            downloadId: torrent.hash,
            queueIds: [],
            title: identity?.title ?? parsed.title,
            episodeLabel: type == .tv ? parsed.episodeLabel : nil,
            tmdbId: identity?.tmdbId,
            tvdbId: nil,
            progress: min(max(torrent.progress, 0), 1),
            secondsLeft: torrent.secondsLeft,
            phase: torrent.phase,
            message: torrent.phase.isProblem ? "qBittorrent reports “\(torrent.state)”." : nil,
            resolvedType: type
        )
    }

    /// Looks up the Seerr title for torrents not seen before. A torrent that matches nothing is remembered
    /// as unmatched, so it isn't searched for again on every refresh.
    private func identify(_ torrents: [QBitTorrent]) async {
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
