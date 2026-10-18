import SwiftUI
import TVServices

@MainActor
@Observable
final class MediaRowModel: Identifiable {
    let section: DiscoverSection
    // Identifiable's `id` must be readable off the main actor; `section` is an immutable Sendable value.
    nonisolated var id: String { section.id }

    private(set) var items: [MediaResult] = []
    private(set) var error: String?

    @ObservationIgnored private var page = 0
    @ObservationIgnored private var totalPages = 1
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var seen = Set<String>()

    init(section: DiscoverSection) {
        self.section = section
    }

    /// Hands the first page of Trending to the Top Shelf extension and asks tvOS to refresh it.
    static func saveForTopShelf(_ items: [MediaResult], section: TopShelfCache.Section) {
        TopShelfCache.save(items.prefix(20).compactMap { item in
            guard let route = item.route else { return nil }
            return TopShelfCache.Item(type: route.type.rawValue, tmdbId: route.tmdbId, title: item.displayTitle,
                                      posterURL: TMDBImage.url(item.posterPath, size: .posterLarge))
        }, for: section)
        // Only the section the Top Shelf is showing needs it redrawn.
        if TopShelfCache.section == section { TVTopShelfContentProvider.topShelfContentDidChange() }
    }

    func loadMore(using api: SeerrClient) async {
        guard !isLoading, page < totalPages else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await api.discover(section, page: page + 1)
            page = response.page
            totalPages = response.totalPages
            // TMDB pages overlap and trending includes people; keep unique, requestable titles.
            let fresh = response.results.filter { $0.route != nil && seen.insert($0.uid).inserted }
            items.append(contentsOf: fresh)
            error = nil
            // Each section is kept for the Top Shelf, which shows whichever one is chosen in Settings.
            if page == 1, let shelf = TopShelfCache.Section(rawValue: section.rawValue) {
                Self.saveForTopShelf(items, section: shelf)
            }
        } catch {
            if items.isEmpty { self.error = AppState.friendly(error) }
        }
    }
}

struct DiscoverView: View {
    @Environment(AppState.self) private var app
    @State private var rows = DiscoverSection.allCases.map { MediaRowModel(section: $0) }
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    SuggestionsRowView(model: app.suggestions)
                    ForEach(rows) { row in
                        MediaRowView(model: row)
                    }
                }
                .padding(.vertical, 30)
            }
            .themedBackground()
            .mediaDestinations()
        }
        .task { await app.suggestions.refresh(api: app.api, userId: app.user?.id) }
        // Pop back to the rows when leaving the tab, so returning always shows the top level.
        .onDisappear { path = NavigationPath() }
        // A title opened from the Top Shelf: show it on top of the rows.
        .onChange(of: app.deepLinkRoute, initial: true) { _, route in
            guard let route else { return }
            path = NavigationPath()
            path.append(route)
            app.deepLinkRoute = nil
        }
    }
}

struct MediaRowView: View {
    @Environment(AppState.self) private var app
    let model: MediaRowModel
    @State private var expanded = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The title is focusable; selecting it opens the whole section full screen.
            Button { expanded = true } label: {
                HStack(spacing: 16) {
                    Text(model.section.title)
                        .font(.title3).fontWeight(.semibold)
                    if titleFocused {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(ThemedButtonStyle(idleFill: false))
            .focused($titleFocused)
            .animation(.easeOut(duration: 0.15), value: titleFocused)

            if let error = model.error {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        if model.items.isEmpty {
                            ForEach(0..<7, id: \.self) { _ in PosterPlaceholder() }
                        }
                        ForEach(model.items, id: \.uid) { item in
                            PosterCard(item: item)
                                .onAppear {
                                    if item.uid == model.items.last?.uid {
                                        Task { await model.loadMore(using: app.api) }
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 30) // room for the focus lift
                }
                .scrollClipDisabled()
            }
        }
        .focusSection()
        .task {
            if model.items.isEmpty { await model.loadMore(using: app.api) }
        }
        .fullScreenCover(isPresented: $expanded) {
            ExpandedSectionView(model: model)
        }
    }
}

/// A whole Discover section as a full-screen grid. Shares the row's model, so paging carries over.
struct ExpandedSectionView: View {
    @Environment(AppState.self) private var app
    let model: MediaRowModel

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 40)]

    var body: some View {
        NavigationStack {
            Group {
                if let error = model.error, model.items.isEmpty {
                    ContentUnavailableView("Couldn't Load \(model.section.title)", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if model.items.isEmpty {
                    ProgressView()
                } else {
                    ScrollView(.vertical) {
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
                        .padding(.vertical, 30) // room for the focus lift
                    }
                    .scrollClipDisabled()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
            .navigationTitle(model.section.title)
            .mediaDestinations()
        }
        .task {
            if model.items.isEmpty { await model.loadMore(using: app.api) }
        }
    }
}

/// "Suggested for You": titles worked out from the user's requests and the server's library (see `SuggestionEngine`).
/// Hidden until there's something to show.
struct SuggestionsRowView: View {
    let model: SuggestionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.items.isEmpty {
                Text("Suggested for You")
                    .font(.title3).fontWeight(.semibold)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(model.items, id: \.uid) { PosterCard(item: $0) }
                    }
                    .padding(.vertical, 30) // room for the focus lift
                }
                .scrollClipDisabled()
            }
        }
        .focusSection()
    }
}
