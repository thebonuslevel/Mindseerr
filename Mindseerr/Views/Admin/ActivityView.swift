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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Your Requests")
                                .font(.title3).fontWeight(.semibold)
                            LazyVStack(spacing: 20) {
                                ForEach(requests) { request in
                                    ActivityRequestRow(request: request)
                                        .onAppear {
                                            if request.id == requests.last?.id { Task { await loadMore() } }
                                        }
                                }
                            }
                        }
                        .padding(.horizontal, 50)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

/// One of the user's requests, as a panel like the Active Downloads ones: the title (opening it when selected) and,
/// while it's downloading, pause and cancel buttons inside the panel. The panel lights up when the title has focus.
private struct ActivityRequestRow: View {
    @Environment(AppState.self) private var app
    @Environment(\.appTheme) private var theme
    let request: MediaRequest
    @State private var detail: MediaDetail?
    @State private var titleFocused = false
    @FocusState private var plainFocused: Bool
    @State private var confirmCancel = false
    @State private var notice: String?

    /// Sonarr/Radarr/torrent-client downloads for this title, when this device has them connected.
    private var downloads: [ArrDownload] {
        app.downloads.downloads.filter { $0.matches(request.media) }
    }

    var body: some View {
        HStack(spacing: 20) {
            if let route = request.route {
                NavigationLink(value: route) { label }
                    .buttonStyle(DownloadLinkStyle(isFocused: $titleFocused))
            } else {
                label
                    .padding(12)
                    .focusable()
                    .focused($plainFocused)
                    .onChange(of: plainFocused) { _, on in titleFocused = on }
            }
            if !downloads.isEmpty {
                DownloadControlButtons(downloads: downloads) { confirmCancel = true }
            }
        }
        .padding(14)
        .background(titleFocused ? theme.highlight.opacity(0.3) : Color.primary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: titleFocused)
        .focusSection()
        .task {
            if let route = request.route { detail = try? await app.api.detail(for: route) }
        }
        .confirmationDialog("Cancel this download?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Download", role: .destructive) { cancelDownloads(blocklist: false) }
            if app.downloads.canBlocklist(downloads) {
                Button("Cancel and Blocklist", role: .destructive) { cancelDownloads(blocklist: true) }
            }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("This removes \(detail?.displayTitle ?? "this title") from the download queue and deletes the partial download from your download client. The request stays in Seerr.\(app.downloads.canBlocklist(downloads) ? " Blocklisting also stops Sonarr or Radarr from grabbing this same release again, so it looks for another." : "")")
        }
        .alert("Download", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func cancelDownloads(blocklist: Bool) {
        let items = downloads
        Task {
            do { try await app.downloads.cancel(items, blocklist: blocklist) } catch { notice = AppState.friendly(error) }
        }
    }

    private var label: some View {
        HStack(spacing: 30) {
            PosterImage(url: TMDBImage.url(detail?.posterPath, size: .poster))
                .frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 10) {
                Text(detail?.displayTitle ?? "Loading…")
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    RequestStatusBadge(status: request.status)
                    if let status = request.secondaryMediaStatus { StatusBadge(status: status) }
                }
                ForEach(downloads) { DownloadProgressLine(download: $0) }
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if request.media?.mediaType == .tv {
            let seasons = (request.seasons ?? []).map(\.seasonNumber).sorted()
            if seasons.isEmpty {
                parts.append("Series")
            } else {
                let list = seasons.map(String.init).joined(separator: ", ")
                parts.append(seasons.count == 1 ? String(localized: "Season \(list)") : String(localized: "Seasons \(list)"))
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
