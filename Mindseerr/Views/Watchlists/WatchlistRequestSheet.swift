import SwiftUI

/// Lets the user pick what to request from a watchlist: which of the missing titles, and for each series
/// which seasons, instead of requesting everything.
struct WatchlistRequestSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let items: [WatchlistItem]
    let onRequest: (WatchlistStore.RequestChoices) -> Void

    private struct SeasonOption: Identifiable {
        let number: Int
        let episodes: Int?
        var id: Int { number }
        var label: String { episodes.map { "Season \(number) · \($0) ep" } ?? "Season \(number)" }
    }

    @State private var loading = true
    /// The seasons that can still be requested, for each series (by item id).
    @State private var options: [String: [SeasonOption]] = [:]
    @State private var selected: [String: Set<Int>] = [:]
    @State private var skipped: Set<String> = []

    private let movieColumns = [GridItem(.adaptive(minimum: 480, maximum: 640), spacing: 20, alignment: .leading)]
    private let columns = [GridItem(.adaptive(minimum: 330, maximum: 420), spacing: 20, alignment: .leading)]

    private func isSeries(_ item: WatchlistItem) -> Bool { (item.route?.type ?? item.entry.kind) == .tv }

    /// Titles that would be requested: movies not skipped, and series with at least one season picked.
    private var chosenCount: Int {
        items.filter { isSeries($0) ? !(selected[$0.id] ?? []).isEmpty : !skipped.contains($0.id) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Choose What to Request")
                .font(.largeTitle).bold()
            Text("Pick the seasons for each series. A title with nothing picked is skipped.")
                .foregroundStyle(.secondary)

            if loading {
                HStack(spacing: 16) {
                    ProgressView()
                    Text("Checking the seasons on your server…").foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        // Movies are a single choice each, so they share a compact grid; series get a row of seasons.
                        let movies = items.filter { !isSeries($0) }
                        if !movies.isEmpty {
                            Text("Movies").font(.title3).fontWeight(.semibold)
                            LazyVGrid(columns: movieColumns, alignment: .leading, spacing: 16) {
                                ForEach(movies) { movieRow($0) }
                            }
                            .focusSection()
                        }
                        ForEach(items.filter(isSeries)) { seriesRow($0) }
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 30) {
                Button {
                    var choices = WatchlistStore.RequestChoices()
                    for item in items {
                        if isSeries(item) {
                            let picked = selected[item.id] ?? []
                            if picked.isEmpty { choices.skipped.insert(item.id) }
                            else { choices.seasons[item.id] = picked.sorted() }
                        } else if skipped.contains(item.id) {
                            choices.skipped.insert(item.id)
                        }
                    }
                    onRequest(choices)
                    dismiss()
                } label: {
                    Label(chosenCount == 1 ? "Request 1 Title" : "Request \(chosenCount) Titles", systemImage: "plus.circle.fill")
                }
                .disabled(loading || chosenCount == 0)

                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .themedBackground()
        .task { await loadSeasons() }
    }

    // MARK: - Rows

    private func movieRow(_ item: WatchlistItem) -> some View {
        Button {
            if skipped.contains(item.id) { skipped.remove(item.id) } else { skipped.insert(item.id) }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: skipped.contains(item.id) ? "circle" : "checkmark.circle.fill")
                Text(item.title)
                if let year = item.year { Text(year).foregroundStyle(.secondary) }
                Text("Movie").font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func seriesRow(_ item: WatchlistItem) -> some View {
        let seasons = options[item.id] ?? []
        let picked = selected[item.id] ?? []
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                Text(item.title).font(.title3).fontWeight(.semibold)
                if let year = item.year { Text(year).foregroundStyle(.secondary) }
                Text("\(picked.count) of \(seasons.count) seasons").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                Button("All") { selected[item.id] = Set(seasons.map(\.number)) }
                Button("None") { selected[item.id] = [] }
            }
            .font(.callout)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(seasons) { season in
                    Button {
                        if picked.contains(season.number) { selected[item.id]?.remove(season.number) }
                        else { selected[item.id, default: []].insert(season.number) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: picked.contains(season.number) ? "checkmark.circle.fill" : "circle")
                            Text(season.label).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .focusSection()
    }

    // MARK: - Loading

    /// Looks up which seasons of each series can still be requested; all of them start picked.
    private func loadSeasons() async {
        let series = items.filter(isSeries)
        let api = app.api
        let found = await boundedMap(series, limit: 4) { item -> (String, [SeasonOption]) in
            guard let route = item.route, let detail = try? await api.detail(for: route, useCache: false) else { return (item.id, []) }
            let open = Set(detail.requestableSeasonNumbers)
            let seasons = (detail.seasons ?? []).filter { open.contains($0.seasonNumber) }
                .map { SeasonOption(number: $0.seasonNumber, episodes: $0.episodeCount) }
                .sorted { $0.number < $1.number }
            return (item.id, seasons)
        }
        for (id, seasons) in found {
            options[id] = seasons
            selected[id] = Set(seasons.map(\.number))
        }
        loading = false
    }
}
