import SwiftUI

struct RequestsView: View {
    @Environment(AppState.self) private var app
    /// Everything fetched, completed requests included; only the unfinished ones are listed.
    @State private var fetched: [MediaRequest] = []
    private var requests: [MediaRequest] { fetched.filter { !$0.isCompleted } }
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
                } else if let error, fetched.isEmpty {
                    ContentUnavailableView("Couldn't Load Requests", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if requests.isEmpty {
                    ContentUnavailableView(fetched.isEmpty ? "No Requests Yet" : "Nothing in Progress",
                                           systemImage: fetched.isEmpty ? "tray" : "checkmark.circle",
                                           description: Text(fetched.isEmpty
                                                ? "Movies and series you request will show up here."
                                                : "Your completed requests are hidden. New ones will show up here."))
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

    /// How many unfinished requests to try to have on screen before waiting for the user to scroll.
    private let minVisible = 8

    private func refresh() async {
        guard let userId = app.user?.id, !loading else { return }
        loading = true
        defer { loading = false; loadedOnce = true }
        do {
            let response = try await app.api.requests(for: userId, skip: 0, take: pageSize)
            fetched = response.results
            page = 1
            totalPages = response.pageInfo.pages
            error = nil
            await fillVisible(userId: userId)
        } catch {
            if fetched.isEmpty { self.error = AppState.friendly(error) }
        }
    }

    private func loadMore() async {
        guard let userId = app.user?.id, !loading, page < totalPages else { return }
        loading = true
        defer { loading = false }
        await fetchNextPage(userId: userId)
        await fillVisible(userId: userId)
    }

    /// Completed requests are hidden, so a page can add little or nothing to the list: keep reading pages until
    /// there's enough to fill the screen, or there are no more.
    private func fillVisible(userId: Int) async {
        while requests.count < minVisible, page < totalPages {
            await fetchNextPage(userId: userId)
        }
    }

    private func fetchNextPage(userId: Int) async {
        do {
            let response = try await app.api.requests(for: userId, skip: page * pageSize, take: pageSize)
            let known = Set(fetched.map(\.id))
            fetched += response.results.filter { !known.contains($0.id) }
            page += 1
            totalPages = response.pageInfo.pages
        } catch {
            // Keep what's already shown, and stop paging; coming back to the tab reloads.
            page = totalPages
        }
    }
}

struct RequestRow: View {
    @Environment(AppState.self) private var app
    let request: MediaRequest
    @State private var detail: MediaDetail?
    @State private var confirmCancel = false
    @State private var notice: String?

    var body: some View {
        HStack(spacing: 20) {
            if let route = request.route {
                NavigationLink(value: route) { label }
            } else {
                label
            }
            // Pause/resume and cancel, while the title is in a Sonarr/Radarr queue.
            if !downloads.isEmpty {
                DownloadControlButtons(downloads: downloads) { confirmCancel = true }
            }
        }
        .focusSection()
        .task {
            if let route = request.route { detail = try? await app.api.detail(for: route) }
        }
        .confirmationDialog("Cancel this download?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Download", role: .destructive) {
                let items = downloads
                Task {
                    do { try await app.downloads.cancel(items) } catch { notice = AppState.friendly(error) }
                }
            }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("This removes \(detail?.displayTitle ?? "this title") from the download queue and deletes the partial download from your download client. The request stays in Seerr.")
        }
        .alert("Download", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
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
