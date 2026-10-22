import SwiftUI

struct SearchView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var results: [MediaResult] = []
    @State private var loading = false
    @State private var error: String?
    @State private var path = NavigationPath()
    @State private var typeFilter: TypeFilter = .all
    @State private var sort: ResultSort = .bestMatch

    private enum TypeFilter: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", series = "Series"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return String(localized: "All")
            case .movies: return String(localized: "Movies")
            case .series: return String(localized: "Series")
            }
        }
    }

    private enum ResultSort: String, CaseIterable {
        case bestMatch = "Best Match", topRated = "Top Rated", newest = "Newest"
        var title: String {
            switch self {
            case .bestMatch: return String(localized: "Best Match")
            case .topRated: return String(localized: "Top Rated")
            case .newest: return String(localized: "Newest")
            }
        }
        var next: ResultSort { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    }

    /// The results as the filter and order ask. Best Match keeps Seerr's own order; the others are stable, so titles
    /// that tie (or have no rating or date) stay in that order. Undated titles go last under Newest.
    private var shown: [MediaResult] {
        let filtered = results.filter {
            switch typeFilter {
            case .all: return true
            case .movies: return $0.type == .movie
            case .series: return $0.type == .tv
            }
        }
        switch sort {
        case .bestMatch: return filtered
        case .topRated:
            return filtered.enumerated().sorted { a, b in
                let (x, y) = (a.element.voteAverage ?? 0, b.element.voteAverage ?? 0)
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
        case .newest:
            return filtered.enumerated().sorted { a, b in
                let (x, y) = (a.element.releaseDate ?? a.element.firstAirDate ?? "", b.element.releaseDate ?? b.element.firstAirDate ?? "")
                if x == y { return a.offset < b.offset }
                if x.isEmpty { return false }
                if y.isEmpty { return true }
                return x > y
            }.map(\.element)
        }
    }

    @Environment(\.appTheme) private var theme
    static let menuClearance: CGFloat = 140
    private static let topID = "search-top"

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 260), spacing: 40, alignment: .top)]

    var body: some View {
        ScrollViewReader { scroll in
        NavigationStack(path: $path) {
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .id(Self.topID)
            }
            .themedBackground()
            .searchable(text: $query, prompt: "Movies and series")
            .task(id: query) { await runSearch() }
            .mediaDestinations()
        }
        // The search field and keyboard are laid out by the system and ignore content margins, so they're pushed clear
        // of the menu as a safe area: that moves the left edge in without cutting off the system's "Hold to dictate" on the
        // right, which plain padding did. The results' own margin is reduced by the same amount (see MainTabView).
        .safeAreaPadding(.leading, SearchView.menuClearance)
        // The system draws a line under the keyboard from the page's left edge, which runs into the collapsed menu. A strip
        // of the page's own background hides its first stretch, so the line starts clear of the menu.
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(theme.background)
                .frame(width: SideMenu.collapsedWidth + 40, height: 14)
                .padding(.top, 207)
                .allowsHitTesting(false)
        }
        // Leaving the tab closes any open title, clears the search and scrolls to the top, so coming back shows
        // the empty Search page. (On the stack itself: a pushed title also hides the results, which mustn't reset anything.)
        .onDisappear {
            path = NavigationPath()
            query = ""
            typeFilter = .all
            sort = .bestMatch
            scroll.scrollTo(Self.topID, anchor: .top)
        }
        }
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmed.isEmpty {
            ContentUnavailableView("Search Seerr", systemImage: "magnifyingglass",
                                   description: Text("Find a movie or series to request."))
                .padding(.top, 80)
        } else if let error {
            ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
                .padding(.top, 80)
        } else if results.isEmpty {
            if loading {
                ProgressView().padding(.top, 120)
            } else {
                ContentUnavailableView.search(text: query).padding(.top, 80)
            }
        } else {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 30) {
                    Picker("Show", selection: $typeFilter) {
                        ForEach(TypeFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 700)
                    Button { sort = sort.next } label: {
                        Label(sort.title, systemImage: "arrow.up.arrow.down")
                    }
                }
                .focusSection()

                if shown.isEmpty {
                    ContentUnavailableView("No \(typeFilter.title) Found", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Nothing in these results matches. Choose All to see everything."))
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                        ForEach(shown, id: \.uid) { item in
                            PosterCard(item: item)
                        }
                    }
                }
            }
            .padding(.vertical, 40)
        }
    }

    private func runSearch() async {
        let text = query.trimmed
        guard !text.isEmpty else {
            results = []
            error = nil
            return
        }
        // Debounce typing on the on-screen keyboard.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        loading = true
        defer { loading = false }
        do {
            let response = try await app.api.search(text)
            guard !Task.isCancelled else { return }
            results = response.results.filter { $0.route != nil }
            error = nil
            // A page holds only about 20 results, which a Movies or Series filter would thin out. Read two more.
            var seen = Set(results.map(\.uid))
            for page in 2...max(2, min(3, response.totalPages)) where page <= response.totalPages {
                guard let more = try? await app.api.search(text, page: page), !Task.isCancelled else { break }
                results += more.results.filter { $0.route != nil && seen.insert($0.uid).inserted }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = AppState.friendly(error)
        }
    }
}
