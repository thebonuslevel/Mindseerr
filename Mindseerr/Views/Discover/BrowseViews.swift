import SwiftUI

/// "Browse" on Discover: four ways in (movie genres, series genres, studios, networks), each opening a page of choices.
struct BrowseRowView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Browse")
                .font(.title3).fontWeight(.semibold)
            HStack(spacing: 30) {
                ForEach(BrowseKind.allCases) { kind in
                    NavigationLink(value: kind) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }
        }
        .focusSection()
    }
}

/// The genres, studios or networks to choose from.
struct BrowseListView: View {
    @Environment(AppState.self) private var app
    let kind: BrowseKind
    @State private var targets: [BrowseTarget] = []
    @State private var loading = true
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 30, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text(kind.title).font(.title3).fontWeight(.semibold)
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if let error {
                    ContentUnavailableView("Couldn't Load \(kind.title)", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                        ForEach(targets, id: \.self) { target in
                            NavigationLink(value: target) {
                                Text(target.name)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
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
        .themedBackground()
        .task { await load() }
    }

    private func load() async {
        switch kind {
        case .studios:
            targets = KnownCompanies.studios.map { BrowseTarget(type: .movie, filter: .studio, id: $0.id, name: $0.name) }
        case .networks:
            targets = KnownCompanies.networks.map { BrowseTarget(type: .tv, filter: .network, id: $0.id, name: $0.name) }
        case .movieGenres, .tvGenres:
            do {
                let type = kind.mediaType
                targets = try await app.api.genres(for: type)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    .map { BrowseTarget(type: type, filter: .genre, id: $0.id, name: $0.name) }
            } catch {
                self.error = AppState.friendly(error)
            }
        }
        loading = false
    }
}

@MainActor
@Observable
private final class BrowseModel {
    let target: BrowseTarget
    private(set) var items: [MediaResult] = []
    private(set) var error: String?
    private(set) var loading = false
    var sort: BrowseSort = .popular {
        didSet { if sort != oldValue { reset() } }
    }

    @ObservationIgnored private var page = 0
    @ObservationIgnored private var totalPages = 1
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var generation = 0

    init(target: BrowseTarget) { self.target = target }

    private func reset() {
        generation += 1
        items = []
        page = 0
        totalPages = 1
        seen = []
        error = nil
        loading = false
    }

    func loadMore(using api: SeerrClient) async {
        guard !loading, page < totalPages else { return }
        loading = true
        let mine = generation
        defer { if mine == generation { loading = false } }
        do {
            let response = try await api.browse(target, sort: sort, page: page + 1)
            // The order was changed while this was loading: its answer is for the old order.
            guard mine == generation else { return }
            page = response.page
            totalPages = response.totalPages
            items += response.results.filter { $0.route != nil && seen.insert($0.uid).inserted }
            error = nil
        } catch {
            if mine == generation, items.isEmpty { self.error = AppState.friendly(error) }
        }
    }
}

/// The titles in one genre, studio or network, with the order switchable from its heading.
struct BrowseResultsView: View {
    @Environment(AppState.self) private var app
    @State private var model: BrowseModel
    @FocusState private var sortFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 260), spacing: 40, alignment: .top)]

    init(target: BrowseTarget) {
        _model = State(initialValue: BrowseModel(target: target))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                // The heading is the control: selecting it moves to the next order.
                Button { model.sort = model.sort.next } label: {
                    HStack(spacing: 16) {
                        Text(model.target.heading).font(.title3).fontWeight(.semibold)
                        Text("·").foregroundStyle(.secondary)
                        Text(model.sort.title).font(.title3).foregroundStyle(.secondary)
                        if sortFocused {
                            Label("Change order", systemImage: "arrow.up.arrow.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(ThemedButtonStyle(idleFill: false))
                .focused($sortFocused)
                .animation(.easeOut(duration: 0.15), value: sortFocused)

                if let error = model.error, model.items.isEmpty {
                    ContentUnavailableView("Couldn't Load Titles", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if model.items.isEmpty {
                    if model.loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
                    else { ContentUnavailableView("Nothing Here", systemImage: "film") }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                        ForEach(model.items, id: \.uid) { item in
                            PosterCard(item: item)
                                .onAppear {
                                    if item.uid == model.items.last?.uid {
                                        Task { await model.loadMore(using: app.api) }
                                    }
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
        .themedBackground()
        .task(id: model.sort) {
            if model.items.isEmpty { await model.loadMore(using: app.api) }
        }
    }
}
