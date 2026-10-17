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

    /// Pauses a running download, or resumes a paused one.
    func togglePause(_ download: ArrDownload) async throws {
        guard let hash = download.downloadId?.lowercased(),
              let owner = torrentOwners[hash], let client = qbitClients[owner] else { return }
        if download.phase == .paused {
            try await client.resume(hash: hash)
        } else {
            try await client.pause(hash: hash)
        }
        await refresh()
    }

    /// Cancels a download: removes it from the Sonarr/Radarr queue and deletes it from the download client.
    func cancel(_ download: ArrDownload) async throws {
        guard let service = services.first(where: { $0.id == download.serviceID }) else { return }
        try await ArrClient.cancel(download, on: service)
        await refresh()
    }

    // MARK: Polling


    /// Refreshes the queues until cancelled. Run it with `.task(id: services)` so it restarts when
    /// services are added or removed.
    func run() async {
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
        let (owners, torrentFailures) = await torrents
        downloads = fresh
        errors = failures.merging(torrentFailures) { first, _ in first }
        torrentOwners = owners
        loaded = true
    }

    /// Reads which torrents each qBittorrent server holds. One that can't be reached reports its error.
    private func readTorrents(_ services: [ArrService]) async -> ([String: UUID], [UUID: String]) {
        var owners: [String: UUID] = [:]
        var failures: [UUID: String] = [:]
        for service in services {
            let client = qbitClients[service.id] ?? QBittorrentClient(service: service)
            qbitClients[service.id] = client
            do {
                for hash in try await client.torrentHashes() { owners[hash] = service.id }
            } catch {
                failures[service.id] = AppState.friendly(error)
            }
        }
        return (owners, failures)
    }
}
