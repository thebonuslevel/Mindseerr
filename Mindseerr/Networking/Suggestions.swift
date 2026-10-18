import Foundation
import Observation

/// Works out a "Suggested for You" list from what's on the Seerr server and what the user has requested.
///
/// 1. Seeds: the user's own requests (weighted heavily) plus titles that are available on the server.
/// 2. Each seed's Seerr recommendations become candidates; a title recommended by several seeds scores higher.
/// 3. Titles already available or requested are dropped.
/// 4. The best candidates are checked against Rotten Tomatoes, and well-rated ones are promoted over poorly rated ones.
enum SuggestionEngine {
    /// How much a recommendation from one of the user's own requests counts, against one from a library title (1).
    static let ownWeight = 3.0
    private static let ownSeeds = 15
    private static let librarySeeds = 40
    /// How many top candidates get a Rotten Tomatoes lookup.
    private static let ratedCandidates = 40
    static let resultCount = 20

    static func suggestions(api: SeerrClient, userId: Int?) async -> [MediaResult] {
        // Seeds.
        var own: [MediaRoute] = []
        if let userId, let page = try? await api.requests(for: userId, skip: 0, take: ownSeeds * 2) {
            own = unique(page.results.compactMap(\.route)).prefix(ownSeeds).map { $0 }
        }
        var library: [MediaRoute] = []
        if let page = try? await api.allRequests(filter: .available, skip: 0, take: librarySeeds * 2) {
            let ownSet = Set(own)
            library = unique(page.results.compactMap(\.route)).filter { !ownSet.contains($0) }.prefix(librarySeeds).map { $0 }
        }
        let seeds: [(route: MediaRoute, weight: Double)] =
            own.enumerated().map { ($1, ownWeight * max(0.5, 1 - Double($0) * 0.04)) } + library.map { ($0, 1.0) }
        guard !seeds.isEmpty else { return [] }

        // Candidates: every seed's recommendations, scored by how many seeds point at them.
        let lists = await boundedMap(seeds, limit: 6) { seed -> [(MediaResult, Double)] in
            let results = (try? await api.related(.recommendations, to: seed.route).results) ?? []
            return results.filter { $0.route != nil && $0.route != seed.route }.map { ($0, seed.weight) }
        }
        let known = Set(seeds.map(\.route))
        var scores: [String: Double] = [:]
        var byID: [String: MediaResult] = [:]
        for (item, weight) in lists.flatMap({ $0 }) {
            guard let route = item.route, !known.contains(route), isOpen(item) else { continue }
            scores[item.uid, default: 0] += weight
            byID[item.uid] = item
        }
        // Slightly favor titles TMDB users rate well, so ties don't fall to whatever came first.
        let ranked = scores.map { id, score -> (MediaResult, Double) in
            let item = byID[id]!
            return (item, score * (1 + (item.voteAverage ?? 6) / 40))
        }.sorted { $0.1 > $1.1 }.prefix(ratedCandidates).map { $0 }

        // Rotten Tomatoes: promote well-rated titles, demote poorly rated ones.
        let rated = await boundedMap(ranked, limit: 6) { entry -> (MediaResult, Double, Double) in
            let rating = await entry.0.route.asyncFlatMap { await api.rottenTomatoes(for: $0) }
            return (entry.0, entry.1, quality(rating: rating, tmdbVote: entry.0.voteAverage))
        }
        var final = rated.map { ($0.0, $0.1 * multiplier(forQuality: $0.2), $0.2) }.sorted { $0.1 > $1.1 }
        // Leave out clearly bad ones, as long as that still leaves a decent list.
        let good = final.filter { $0.2 >= 40 }
        if good.count >= 8 { final = good }
        return final.prefix(resultCount).map(\.0)
    }

    /// A 0...100 quality score: the critics' Rotten Tomatoes score, averaged with the audience score when there
    /// is one. Without Rotten Tomatoes, TMDB's rating stands in for it.
    static func quality(rating: RottenTomatoesRating?, tmdbVote: Double?) -> Double {
        if let rating, rating.hasScore {
            let scores = [rating.criticsScore, rating.audienceScore].compactMap { $0 }.map(Double.init)
            return scores.reduce(0, +) / Double(scores.count)
        }
        if let tmdbVote, tmdbVote > 0 { return tmdbVote * 10 }
        return 60   // nothing known: neither promoted nor demoted much
    }

    /// 0% quality counts 0.4x and 100% counts 1.6x, so a well-rated title beats a poorly rated one of similar relevance.
    static func multiplier(forQuality quality: Double) -> Double {
        0.4 + 1.2 * min(max(quality, 0), 100) / 100
    }

    /// Not already on the server or in the request pipeline.
    private static func isOpen(_ item: MediaResult) -> Bool {
        switch item.mediaInfo?.status {
        case .available, .partiallyAvailable, .processing, .pending: return false
        case .unknown, .deleted, nil: return true
        }
    }

    private static func unique(_ routes: [MediaRoute]) -> [MediaRoute] {
        var seen = Set<MediaRoute>()
        return routes.filter { seen.insert($0).inserted }
    }
}

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}

/// The suggestions shown on Discover. Cached for a few hours so they aren't recomputed on every visit.
@MainActor
@Observable
final class SuggestionsModel {
    private(set) var items: [MediaResult] = []
    private(set) var loading = false
    @ObservationIgnored private var loadedAt: Date?

    private let freshFor: TimeInterval = 3 * 3600

    func refresh(api: SeerrClient, userId: Int?, force: Bool = false) async {
        guard !loading else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < freshFor, !items.isEmpty { return }
        loading = true
        defer { loading = false }
        let fresh = await SuggestionEngine.suggestions(api: api, userId: userId)
        guard !Task.isCancelled else { return }
        items = fresh
        loadedAt = Date()
    }
}
