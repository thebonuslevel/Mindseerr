import SwiftUI

struct SearchView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var results: [MediaResult] = []
    @State private var loading = false
    @State private var error: String?
    @State private var path = NavigationPath()

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
        // Leaving the tab closes any open title, clears the search and scrolls to the top, so coming back shows
        // the empty Search page. (On the stack itself: a pushed title also hides the results, which mustn't reset anything.)
        .onDisappear {
            path = NavigationPath()
            query = ""
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
            LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                ForEach(results, id: \.uid) { item in
                    PosterCard(item: item)
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
        } catch {
            guard !Task.isCancelled else { return }
            self.error = AppState.friendly(error)
        }
    }
}
