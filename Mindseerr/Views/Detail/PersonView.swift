import SwiftUI

/// A cast or crew member's page: who they are, and the other movies and series they've worked on, best-rated first
/// (by their Rotten Tomatoes Tomatometer, with TMDB's rating standing in where there is none).
struct PersonView: View {
    @Environment(AppState.self) private var app
    let person: PersonRoute

    private struct Work: Identifiable {
        let item: MediaResult
        var rating: RottenTomatoesRating?
        /// 0...100, used for the order: the Tomatometer shown on the card, or TMDB's rating (x10) without one.
        var quality: Double
        var id: String { item.uid }
    }

    @State private var detail: PersonDetail?
    @State private var works: [Work] = []
    @State private var loading = true

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 260), spacing: 40, alignment: .top)]
    /// How many of a person's titles get a Rotten Tomatoes lookup; the rest follow, ordered by TMDB's rating.
    private let ratedLimit = 60

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                if loading && works.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if works.isEmpty {
                    ContentUnavailableView("No Other Work Found", systemImage: "film",
                                           description: Text("There's nothing else listed for \(person.name)."))
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Best Rated First")
                        .font(.title3).fontWeight(.semibold)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                        ForEach(works) { work in
                            VStack(alignment: .leading, spacing: 8) {
                                PosterCard(item: work.item)
                                scoreLine(for: work)
                            }
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .task { await load() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 40) {
            ZStack {
                Circle().fill(.quaternary)
                if let url = TMDBImage.url(detail?.profilePath ?? person.profilePath, size: .profile) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Text(person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                        .font(.largeTitle).bold().foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 12) {
                Text(person.name).font(.largeTitle).bold()
                if let line = infoLine {
                    Text(line).font(.callout).foregroundStyle(.secondary)
                }
                if let bio = detail?.biography, !bio.isEmpty {
                    Text(bio)
                        .font(.body)
                        .lineLimit(4)
                        .frame(maxWidth: 1200, alignment: .leading)
                }
            }
        }
    }

    private var infoLine: String? {
        var parts: [String] = []
        if let department = detail?.knownForDepartment, !department.isEmpty { parts.append(department) }
        if let birthday = detail?.birthday, birthday.count >= 4 { parts.append("Born \(birthday.prefix(4))") }
        if let place = detail?.placeOfBirth, !place.isEmpty { parts.append(place) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func scoreLine(for work: Work) -> some View {
        if let critics = work.rating?.criticsScore {
            Text("\(critics >= 60 ? "🍅" : "🤢") \(critics)%").font(.caption).monospacedDigit()
        } else if let vote = work.item.voteAverage, vote > 0 {
            Text(String(format: "★ %.1f", vote)).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Loading

    /// What the order is based on, so it always matches the score printed on the card.
    private static func quality(rating: RottenTomatoesRating?, vote: Double?) -> Double {
        if let critics = rating?.criticsScore { return Double(critics) }
        return (vote ?? 0) * 10
    }

    private func load() async {
        async let info = try? await app.api.person(person.id)
        let credits = try? await app.api.credits(forPerson: person.id)
        detail = await info

        // Movies and series only, each once (an actor-director shows up in both lists), with a poster to show.
        var seen = Set<String>()
        let all = ((credits?.cast ?? []) + (credits?.crew ?? [])).filter {
            $0.route != nil && $0.posterPath != nil && seen.insert($0.uid).inserted
        }
        let byVote = all.sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
        // Show them right away in TMDB order, then re-sort as Rotten Tomatoes scores arrive.
        works = byVote.map { Work(item: $0, rating: nil, quality: Self.quality(rating: nil, vote: $0.voteAverage)) }
        loading = false

        let api = app.api
        let rated = await boundedMap(Array(byVote.prefix(ratedLimit)), limit: 6) { item -> (String, RottenTomatoesRating?) in
            guard let route = item.route else { return (item.uid, nil) }
            return (item.uid, await api.rottenTomatoes(for: route))
        }
        let ratings = Dictionary(rated.compactMap { id, rating in rating.map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        guard !Task.isCancelled else { return }
        works = byVote.map { item in
            let rating = ratings[item.uid]
            return Work(item: item, rating: rating, quality: Self.quality(rating: rating, vote: item.voteAverage))
        }
        // Highest first; the sort is stable, so ties keep their TMDB order.
        .enumerated().sorted { ($0.element.quality, -$0.offset) > ($1.element.quality, -$1.offset) }.map(\.element)
    }
}
