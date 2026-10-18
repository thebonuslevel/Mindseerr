import Foundation
import Observation

/// Works out a "Suggested for You" list from what's on the Seerr server and what the user has requested.
///
/// Four things are balanced: taste is half of a title's score, Rotten Tomatoes a quarter, and trending and new an eighth each:
/// 1. **Taste**: Seerr's recommendations for the user's own requests (weighted heavily) and the server's available
///    titles. A title several of them point at scores higher.
/// 2. **Trending**: where the title sits on Seerr's Trending list. Trending titles that nothing recommended still
///    enter as candidates, so what's popular right now can surface.
/// 3. **New**: how recently it came out (or is about to). Fresh releases score highest, fading over about three years.
/// 4. **Rotten Tomatoes**: the Tomatometer, averaged with the audience score when there is one (TMDB's rating stands
///    in without one). Well-rated titles are promoted and poorly rated ones demoted.
///
/// Anything already available or requested is dropped.
enum SuggestionEngine {
    /// How much a recommendation from one of the user's own requests counts, against one from a library title (1).
    static let ownWeight = 3.0
    private static let ownSeeds = 15
    private static let librarySeeds = 40
    /// How many top candidates get a Rotten Tomatoes lookup.
    private static let ratedCandidates = 60
    /// Seerr's Trending pages to read (20 titles each).
    private static let trendingPages = 3
    static let resultCount = 40

    /// The four weights; they add up to 1.
    private static let tasteWeight = 0.5, qualityWeight = 0.25, trendingWeight = 0.125, newWeight = 0.125

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

        // Trending, read alongside the seeds' recommendations.
        async let trendingTask = trending(api: api)
        let lists = await boundedMap(seeds, limit: 6) { seed -> [(MediaResult, Double)] in
            let results = (try? await api.related(.recommendations, to: seed.route).results) ?? []
            return results.filter { $0.route != nil && $0.route != seed.route }.map { ($0, seed.weight) }
        }
        let trending = await trendingTask

        // Taste: how many seeds recommend each title, weighted.
        let known = Set(seeds.map(\.route))
        var taste: [String: Double] = [:]
        var byID: [String: MediaResult] = [:]
        for (item, weight) in lists.flatMap({ $0 }) {
            guard let route = item.route, !known.contains(route), isOpen(item) else { continue }
            taste[item.uid, default: 0] += weight
            byID[item.uid] = item
        }
        // Trending titles join the candidates even if nothing recommended them.
        var trendScore: [String: Double] = [:]
        for (rank, item) in trending.enumerated() {
            guard let route = item.route, !known.contains(route), isOpen(item) else { continue }
            trendScore[item.uid] = 1 - Double(rank) / Double(max(trending.count, 1))
            byID[item.uid] = byID[item.uid] ?? item
        }
        guard !byID.isEmpty else { return [] }
        let topTaste = max(taste.values.max() ?? 1, 1)

        // Everything except Rotten Tomatoes, which is only looked up for the best of these.
        struct Candidate {
            let item: MediaResult
            let taste: Double, trending: Double, new: Double
        }
        let candidates = byID.map { id, item in
            Candidate(item: item, taste: (taste[id] ?? 0) / topTaste, trending: trendScore[id] ?? 0, new: newness(of: item))
        }
        // Best by everything but quality first, with the weights above, so the lookups go to the likeliest winners.
        func partial(_ c: Candidate) -> Double { tasteWeight * c.taste + trendingWeight * c.trending + newWeight * c.new }
        let shortlist = candidates.sorted { partial($0) > partial($1) }.prefix(ratedCandidates)

        let rated = await boundedMap(Array(shortlist), limit: 6) { candidate -> (Candidate, Double) in
            let rating = await candidate.item.route.asyncFlatMap { await api.rottenTomatoes(for: $0) }
            return (candidate, quality(rating: rating, tmdbVote: candidate.item.voteAverage))
        }
        var final = rated.map { candidate, quality -> (MediaResult, Double, Double) in
            let score = tasteWeight * candidate.taste + trendingWeight * candidate.trending
                + newWeight * candidate.new + qualityWeight * quality / 100
            return (candidate.item, score, quality)
        }.sorted { $0.1 > $1.1 }
        // Leave out clearly bad ones, as long as that still leaves a decent list.
        let good = final.filter { $0.2 >= 40 }
        if good.count >= 8 { final = good }
        return final.prefix(resultCount).map(\.0)
    }

    /// The first pages of Seerr's Trending list, in order.
    private static func trending(api: SeerrClient) async -> [MediaResult] {
        var items: [MediaResult] = []
        var seen = Set<String>()
        for page in 1...trendingPages {
            guard let response = try? await api.discover(.trending, page: page) else { break }
            items += response.results.filter { $0.route != nil && seen.insert($0.uid).inserted }
            if page >= response.totalPages { break }
        }
        return items
    }

    /// 0...1: 1 for anything out in the last three months (or due in the next six), fading to 0 at three years old.
    static func newness(of item: MediaResult, now: Date = Date()) -> Double {
        guard let text = item.releaseDate ?? item.firstAirDate, text.count >= 10 else { return 0.3 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(text.prefix(10))) else { return 0.3 }
        let days = now.timeIntervalSince(date) / 86_400
        if days < -180 { return 0.5 }          // far-off announcements are less interesting than what's out or imminent
        if days <= 90 { return 1 }
        return max(0, 1 - (days - 90) / (1095 - 90))
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
        MediaRowModel.saveForTopShelf(fresh, section: .suggested)
    }
}
