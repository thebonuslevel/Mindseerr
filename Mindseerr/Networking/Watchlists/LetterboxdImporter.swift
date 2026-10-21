import Foundation

/// Reads a member's public Letterboxd watchlist from letterboxd.com. Letterboxd's API is invite-only,
/// so there's no sign-in: the watchlist has to be public. Each film is matched through the TMDB link
/// on its Letterboxd page; matches are cached so later refreshes only look up new films.
enum LetterboxdImporter {
    private struct Film: Codable {
        let title: String
        let year: Int?
        let kind: MediaType?
        let tmdbId: Int?
        let imdbId: String?
    }

    private static let cacheKey = "letterboxdFilmCache"
    private static let maxPages = 60

    /// Accepts "name", "@name" or a letterboxd.com profile/watchlist link.
    static func username(from input: String) -> String? {
        var text = input.trimmed
        if let r = text.range(of: "letterboxd.com/", options: .caseInsensitive) {
            text = String(text[r.upperBound...])
        }
        text = text.split(separator: "/").first.map(String.init) ?? ""
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        guard !text.isEmpty, text.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else { return nil }
        return text.lowercased()
    }

    static func fetchWatchlist(
        username: String,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> [WatchlistEntry] {
        // 1. Collect film slugs from each watchlist page, in order.
        var slugs: [String] = []
        var seen = Set<String>()
        for page in 1...maxPages {
            try Task.checkCancellation()
            await progress("Reading watchlist page \(page)…")
            guard let url = URL(string: "https://letterboxd.com/\(username)/watchlist/page/\(page)/") else { break }
            let (html, status) = try await WebPage.fetch(url)
            if status == 404 {
                if page == 1 { throw APIError(status: 404, message: String(localized: "There's no Letterboxd member called “\(username)”.")) }
                break
            }
            guard (200..<300).contains(status) else {
                if page == 1 { throw blocked(status) }
                break
            }
            let found = parseSlugs(html).filter { seen.insert($0).inserted }
            if found.isEmpty { break }
            slugs += found
        }
        guard !slugs.isEmpty else {
            throw APIError(status: 0, message:
                "\(username)'s Letterboxd watchlist is empty or hidden. Make sure it's public in your Letterboxd privacy settings.")
        }

        // 2. Match films that aren't cached yet, a few at a time.
        var cache = loadCache()
        let todo = slugs.filter { cache[$0] == nil }
        var failures = 0
        var firstError: Error?
        for start in stride(from: 0, to: todo.count, by: 12) {
            try Task.checkCancellation()
            let chunk = Array(todo[start..<min(start + 12, todo.count)])
            await progress("Matching films \(start + 1)–\(start + chunk.count) of \(todo.count)…")
            let results = await boundedMap(chunk, limit: 4) { slug -> (String, Result<Film, Error>) in
                do { return (slug, .success(try await resolveFilm(slug))) } catch { return (slug, .failure(error)) }
            }
            for (slug, result) in results {
                switch result {
                case .success(let film): cache[slug] = film
                case .failure(let error):
                    failures += 1
                    if firstError == nil { firstError = error }
                }
            }
            // If Letterboxd turns away every film lookup from the start, stop and say so.
            if start == 0, failures == chunk.count, let firstError { saveCache(cache); throw firstError }
        }
        saveCache(cache)

        return slugs.map { slug in
            let film = cache[slug]
            return WatchlistEntry(id: "letterboxd:\(slug)", source: .letterboxd,
                                  title: film?.title ?? prettify(slug), year: film?.year,
                                  kind: film?.kind, tmdbId: film?.tmdbId, imdbId: film?.imdbId)
        }
    }

    // MARK: - Parsing

    /// Film slugs on a watchlist page. Handles both the older poster markup and the newer React one.
    static func parseSlugs(_ html: String) -> [String] {
        let pattern = #"data-(?:film|item)-slug="([^"]+)"|data-(?:target|item)-link="/film/([^/"]+)/""#
        var seen = Set<String>()
        return TextMatch.all(pattern, in: html).filter { seen.insert($0).inserted }
    }

    private static func resolveFilm(_ slug: String) async throws -> Film {
        guard let url = URL(string: "https://letterboxd.com/film/\(slug)/") else {
            throw APIError(status: 0, message: String(localized: "Bad film link."))
        }
        let (html, status) = try await WebPage.fetch(url)
        guard (200..<300).contains(status) else { throw blocked(status) }

        var kind: MediaType?
        var tmdbId: Int?
        if let type = TextMatch.first(#"data-tmdb-type="(movie|tv)""#, in: html)?.first,
           let id = TextMatch.first(#"data-tmdb-id="(\d+)""#, in: html)?.first {
            kind = MediaType(rawValue: type)
            tmdbId = Int(id)
        } else if let groups = TextMatch.first(#"themoviedb\.org/(movie|tv)/(\d+)"#, in: html) {
            kind = MediaType(rawValue: groups[0])
            tmdbId = Int(groups[1])
        }
        let imdbId = TextMatch.first(#"imdb\.com/title/(tt\d+)"#, in: html)?.first

        let rawTitle = TextMatch.first(#"<meta property="og:title" content="([^"]*)""#, in: html)?.first
        let (title, year) = TextMatch.splitYear(TextMatch.decodeEntities(rawTitle ?? prettify(slug)))
        return Film(title: title, year: year, kind: kind, tmdbId: tmdbId, imdbId: imdbId)
    }

    private static func prettify(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func blocked(_ status: Int) -> APIError {
        APIError(status: status, message:
            "Letterboxd turned the request away (error \(status)). It may be blocking apps from reading pages. Try again later, or import your Letterboxd watchlist into Trakt and use the Trakt tab.")
    }

    // MARK: - Cache

    private static func loadCache() -> [String: Film] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode([String: Film].self, from: data) else { return [:] }
        return cache
    }

    private static func saveCache(_ cache: [String: Film]) {
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }
}
