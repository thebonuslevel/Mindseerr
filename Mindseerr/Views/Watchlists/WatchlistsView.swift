import SwiftUI

struct WatchlistsView: View {
    @Environment(AppState.self) private var app
    @State private var store = WatchlistStore()
    @State private var missingOnly = false
    @State private var showTraktSignIn = false
    @State private var showTMDBSignIn = false
    @State private var confirmRequestAll = false
    @State private var confirmDisconnect = false
    @State private var summary: String?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 260), spacing: 40, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Picker("Watchlist", selection: $store.source) {
                        ForEach(WatchlistSource.allCases) { source in
                            Text(source.name).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 1300)

                    if store.isConnected(store.source) {
                        header
                        grid
                    } else {
                        WatchlistConnectView(store: store, source: store.source) {
                            if store.source == .tmdb { showTMDBSignIn = true } else { showTraktSignIn = true }
                        }
                    }
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .themedBackground()
            .mediaDestinations()
            // Re-check statuses when coming back from a detail page, in case something was requested.
            .onAppear { Task { await store.resolve(store.source, api: app.api) } }
        }
        .task { await store.load(api: app.api) }
        .onChange(of: store.source) { _, newSource in
            Task { await store.resolve(newSource, api: app.api) }
        }
        .sheet(isPresented: $showTraktSignIn) {
            TraktSignInView(store: store)
        }
        .sheet(isPresented: $showTMDBSignIn) {
            TMDBSignInView(store: store)
        }
        .confirmationDialog("Request \(store.missingCount(store.source)) titles that aren't on your server?",
                            isPresented: $confirmRequestAll, titleVisibility: .visible) {
            Button("Request All") {
                let source = store.source
                Task {
                    let result = await store.requestAllMissing(source, api: app.api)
                    var text = result.sent == 1 ? "Requested 1 title." : "Requested \(result.sent) titles."
                    if result.failed > 0 {
                        text += " \(result.failed) couldn't be requested"
                        text += result.firstError.map { ": \($0)" } ?? "."
                    }
                    summary = text
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Series are requested for every season that isn't already available or requested.")
        }
        .confirmationDialog("Disconnect \(store.source.name)?", isPresented: $confirmDisconnect,
                            titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                let source = store.source
                Task { await store.disconnect(source) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The imported titles are removed from Mindseerr. Nothing changes on \(store.source.name) or your server.")
        }
        .alert("Requests Sent", isPresented: Binding(
            get: { summary != nil },
            set: { if !$0 { summary = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(summary ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        let source = store.source
        let missing = store.missingCount(source)
        let busy = store.isBusy(source)

        return VStack(alignment: .leading, spacing: 18) {
            Text(store.accountLine(source))
                .font(.title3).fontWeight(.semibold)
            Text(store.summaryLine(source))
                .font(.callout)
                .foregroundStyle(.secondary)

            if let progress = store.requestProgress {
                Label(progress, systemImage: "paperplane")
                    .foregroundStyle(.secondary)
            } else {
                switch store.phase[source] ?? .idle {
                case .working(let message):
                    HStack(spacing: 16) {
                        ProgressView()
                        Text(message).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 1400, alignment: .leading)
                case .idle:
                    EmptyView()
                }
            }

            HStack(spacing: 30) {
                Button {
                    confirmRequestAll = true
                } label: {
                    Label("Request All Missing (\(missing))", systemImage: "plus.circle.fill")
                }
                .disabled(missing == 0 || busy)

                Button {
                    Task { await store.refresh(source, api: app.api) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(busy)

                Button {
                    missingOnly.toggle()
                } label: {
                    Label(missingOnly ? "Show All" : "Not on Server Only",
                          systemImage: missingOnly ? "square.grid.2x2" : "line.3.horizontal.decrease.circle")
                }

                Button(role: .destructive) {
                    confirmDisconnect = true
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .disabled(busy)
            }
        }
        .focusSection()
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        let items = store.visibleItems(store.source, missingOnly: missingOnly)
        if items.isEmpty {
            if case .working = store.phase[store.source] ?? .idle {
                EmptyView()
            } else {
                ContentUnavailableView(missingOnly ? "Everything's Covered" : "Nothing Imported Yet",
                                       systemImage: missingOnly ? "checkmark.circle" : "tray",
                                       description: Text(missingOnly
                                            ? "Every title on this watchlist is already on your server or requested."
                                            : "Choose Refresh to import this watchlist."))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                ForEach(items) { item in
                    WatchlistCard(item: item)
                }
            }
        }
    }
}

// MARK: - Card

struct WatchlistCard: View {
    let item: WatchlistItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let route = item.route {
                NavigationLink(value: route) { poster }
                    .buttonStyle(.card)
            } else {
                // Unmatched titles can't be opened; keep them visible but not selectable.
                poster
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .opacity(0.5)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.caption)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 240, alignment: .leading)
    }

    private var poster: some View {
        PosterImage(url: item.posterURL, title: item.title)
            .frame(width: 240, height: 360)
            .overlay(alignment: .topTrailing) {
                WatchlistBadge(status: item.status).padding(10)
            }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = item.year { parts.append(year) }
        switch item.route?.type ?? item.entry.kind {
        case .tv: parts.append("Series")
        case .movie: parts.append("Movie")
        default: break
        }
        if item.status == .notFound { parts.append("No match") }
        if item.status == .unchecked { parts.append("Couldn't check") }
        return parts.joined(separator: " · ")
    }
}

struct WatchlistBadge: View {
    let status: WatchlistStatus

    var body: some View {
        switch status {
        case .available: Pill(text: "Available", color: .green)
        case .partial: Pill(text: "Partial", color: .teal)
        case .requested: Pill(text: "Requested", color: .indigo)
        case .notFound: Pill(text: "No Match", color: .gray)
        case .matching, .unchecked, .missing: EmptyView()
        }
    }
}
