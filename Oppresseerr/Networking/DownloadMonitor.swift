import Foundation
import Observation

/// The connected Sonarr/Radarr servers and what they're downloading, shared by the whole app so
/// posters, detail pages and the Admin tab all show the same progress.
@MainActor
@Observable
final class DownloadMonitor {
    private(set) var services: [ArrService] = ArrServiceStore.load()
    private(set) var downloads: [ArrDownload] = []
    /// Why a service couldn't be read on the last refresh.
    private(set) var errors: [UUID: String] = [:]
    /// False until the first refresh after the services changed.
    private(set) var loaded = false

    private let refreshInterval: Duration = .seconds(10)

    // MARK: Services

    func add(_ service: ArrService) {
        services.append(service)
        ArrServiceStore.save(services)
    }

    func remove(_ service: ArrService) {
        services.removeAll { $0.id == service.id }
        errors[service.id] = nil
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

    // MARK: Polling

    /// Refreshes the queues until cancelled. Run it with `.task(id: services)` so it restarts when
    /// services are added or removed.
    func run() async {
        loaded = false
        guard !services.isEmpty else {
            downloads = []
            errors = [:]
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
        let current = services
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
        downloads = fresh
        errors = failures
        loaded = true
    }
}
