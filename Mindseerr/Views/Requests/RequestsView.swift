import SwiftUI

struct RequestsView: View {
    @Environment(AppState.self) private var app
    @State private var requests: [MediaRequest] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var error: String?
    @State private var path = NavigationPath()

    private let pageSize = 20

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if requests.isEmpty && !loadedOnce {
                    ProgressView()
                } else if let error, requests.isEmpty {
                    ContentUnavailableView("Couldn't Load Requests", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if requests.isEmpty {
                    ContentUnavailableView("No Requests Yet", systemImage: "tray",
                                           description: Text("Movies and series you request will show up here."))
                } else {
                    List {
                        ForEach(requests) { request in
                            RequestRow(request: request)
                                .onAppear {
                                    if request.id == requests.last?.id {
                                        Task { await loadMore() }
                                    }
                                }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
            .mediaDestinations()
        }
        // Runs each time the tab appears, so new requests show up.
        .task { await refresh() }
        // Pop back to the list when leaving the tab, so returning always shows the list.
        .onDisappear { path = NavigationPath() }
    }

    private func refresh() async {
        guard let userId = app.user?.id, !loading else { return }
        loading = true
        defer { loading = false; loadedOnce = true }
        do {
            let response = try await app.api.requests(for: userId, skip: 0, take: pageSize)
            requests = response.results
            page = 1
            totalPages = response.pageInfo.pages
            error = nil
        } catch {
            if requests.isEmpty { self.error = AppState.friendly(error) }
        }
    }

    private func loadMore() async {
        guard let userId = app.user?.id, !loading, page < totalPages else { return }
        loading = true
        defer { loading = false }
        do {
            let response = try await app.api.requests(for: userId, skip: page * pageSize, take: pageSize)
            let known = Set(requests.map(\.id))
            requests += response.results.filter { !known.contains($0.id) }
            page += 1
            totalPages = response.pageInfo.pages
        } catch {
            // Keep what's already shown; scrolling to the end again retries.
        }
    }
}

struct RequestRow: View {
    @Environment(AppState.self) private var app
    let request: MediaRequest
    @State private var detail: MediaDetail?

    var body: some View {
        Group {
            if let route = request.route {
                NavigationLink(value: route) { label }
            } else {
                label
            }
        }
        .task {
            if let route = request.route { detail = try? await app.api.detail(for: route) }
        }
    }

    /// Sonarr/Radarr downloads for this request's title; Sonarr may list several episodes.
    private var downloads: [ArrDownload] {
        app.downloads.downloads.filter { $0.matches(request.media) }
    }

    private var label: some View {
        HStack(spacing: 30) {
            PosterImage(url: TMDBImage.url(detail?.posterPath, size: .poster))
                .frame(width: 100, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Text(detail?.displayTitle ?? "Loading…")
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    RequestStatusBadge(status: request.status)
                    if let status = request.secondaryMediaStatus {
                        StatusBadge(status: status)
                    }
                }
                ForEach(downloads) { download in
                    DownloadProgressLine(download: download)
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        var parts: [String] = []
        if request.media?.mediaType == .tv {
            let seasons = (request.seasons ?? []).map(\.seasonNumber).sorted()
            if seasons.isEmpty {
                parts.append("Series")
            } else {
                let list = seasons.map(String.init).joined(separator: ", ")
                parts.append(seasons.count == 1 ? "Season \(list)" : "Seasons \(list)")
            }
        } else {
            parts.append("Movie")
        }
        if let year = detail?.year { parts.append(year) }
        if let date = request.createdDateText { parts.append("Requested \(date)") }
        return parts.joined(separator: "  ·  ")
    }
}
