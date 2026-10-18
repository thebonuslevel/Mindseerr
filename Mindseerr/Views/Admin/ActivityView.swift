import SwiftUI

/// The Activity tab, for everyone. Admins and users with the Manage Requests permission get the full panel
/// (every request, approvals, download services and controls); everyone else gets their own requests.
struct ActivityView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.user?.canManageRequests == true {
            AdminView()
        } else {
            MyActivityView()
        }
    }
}

/// A regular user's Activity tab: their own requests that aren't finished yet, with where each one stands.
struct MyActivityView: View {
    @Environment(AppState.self) private var app
    @State private var fetched: [MediaRequest] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var error: String?
    @State private var path = NavigationPath()

    private let pageSize = 20
    /// How many unfinished requests to try to have on screen before waiting for the user to scroll.
    private let minVisible = 8

    private var requests: [MediaRequest] { fetched.filter { !$0.isCompleted } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if requests.isEmpty && !loadedOnce {
                    ProgressView()
                } else if let error, fetched.isEmpty {
                    ContentUnavailableView("Couldn't Load Your Requests", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if requests.isEmpty {
                    ContentUnavailableView(fetched.isEmpty ? "No Requests Yet" : "Nothing in Progress",
                                           systemImage: fetched.isEmpty ? "tray" : "checkmark.circle",
                                           description: Text(fetched.isEmpty
                                                ? "Movies and series you request will show up here."
                                                : "Your completed requests are hidden. New ones will show up here."))
                } else {
                    List {
                        Section("Your Requests") {
                            ForEach(requests) { request in
                                ActivityRequestRow(request: request)
                                    .onAppear {
                                        if request.id == requests.last?.id { Task { await loadMore() } }
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

    /// Completed requests are hidden, so keep reading pages until there's enough to fill the screen.
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
            page = totalPages   // stop paging; coming back to the tab reloads
        }
    }
}

/// One of the user's requests: poster, title, what was requested and where it stands, opening the title when selected.
private struct ActivityRequestRow: View {
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

    /// Sonarr/Radarr downloads for this title, when this device has them connected.
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
                    if let status = request.secondaryMediaStatus { StatusBadge(status: status) }
                }
                ForEach(downloads) { DownloadProgressLine(download: $0) }
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
        if request.is4k == true { parts.append("4K") }
        if let date = request.createdDateText { parts.append("Requested \(date)") }
        return parts.joined(separator: "  ·  ")
    }
}
