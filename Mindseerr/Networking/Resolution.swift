import Foundation
import Observation

/// Which titles in the library are 4K, read from the files Radarr and Sonarr hold. Seerr only knows about 4K when a
/// separate 4K server is linked to it, so this fills in the rest. Movies come from one list per Radarr; a series is
/// looked up in Sonarr when its page opens.
@MainActor
@Observable
final class ResolutionLibrary {
    private(set) var movies: Set<Int> = []
    private(set) var series: [Int: Bool] = [:]
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadedFor: Set<UUID> = []

    func is4K(type: MediaType, tmdbId: Int) -> Bool {
        type == .movie ? movies.contains(tmdbId) : series[tmdbId] == true
    }

    /// Reads the movie lists again if they're older than an hour or the Radarr servers changed.
    func refreshMovies(services: [ArrService]) async {
        let radarrs = services.filter { $0.kind == .radarr }
        let ids = Set(radarrs.map(\.id))
        if loadedFor == ids, let loadedAt, Date().timeIntervalSince(loadedAt) < 3600 { return }
        var found = Set<Int>()
        var reached = false
        for service in radarrs {
            if let set = try? await ArrClient.movieIDsIn4K(from: service) { found.formUnion(set); reached = true }
        }
        guard reached || radarrs.isEmpty else { return }
        movies = found
        loadedFor = ids
        loadedAt = Date()
    }

    /// Looks a series up in each Sonarr, once per launch.
    func loadSeries(tmdbId: Int, tvdbId: Int?, services: [ArrService]) async {
        guard series[tmdbId] == nil else { return }
        var result: Bool?
        for service in services where service.kind == .sonarr {
            if let answer = try? await ArrClient.seriesIs4K(tmdbId: tmdbId, tvdbId: tvdbId, from: service) {
                result = (result ?? false) || answer
            }
        }
        if let result { series[tmdbId] = result }
    }
}
