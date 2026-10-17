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
    @State private var pendingDelete: MediaRequest?
    @State private var deletingIDs: Set<Int> = []
    @State private var notice: String?

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
                            RequestRow(request: request,
                                       deleting: deletingIDs.contains(request.id),
                                       onDelete: deleteAction(for: request))
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
            .navigationTitle("My Requests")
            .mediaDestinations()
        }
        // Runs each time the tab appears, so new requests show up.
        .task { await refresh() }
        // Pop back to the list when leaving the tab, so returning always shows the list.
        .onDisappear { path = NavigationPath() }
        .confirmationDialog("Delete this request?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { request in
            Button("Delete Request", role: .destructive) { delete(request) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the request from Seerr. Anything already downloaded stays on your server.")
        }
        .alert("Couldn't Delete Request", isPresented: Binding(get: { notice != nil },
                                                               set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    /// Seerr lets people delete their own requests while they're waiting for approval;
    /// anyone who can manage requests can delete any of them.
    private func canDelete(_ request: MediaRequest) -> Bool {
        app.user?.canManageRequests == true || request.status == .pendingApproval
    }

    /// The row's Delete action, or nil to hide the button.
    private func deleteAction(for request: MediaRequest) -> (() -> Void)? {
        guard canDelete(request) else { return nil }
        return { pendingDelete = request }
    }

    private func delete(_ request: MediaRequest) {
        let id = request.id
        Task {
            deletingIDs.insert(id)
            defer { deletingIDs.remove(id) }
            do {
                try await app.api.deleteRequest(id: id)
                requests.removeAll { $0.id == id }
            } catch {
                notice = AppState.friendly(error)
            }
        }
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
    var deleting = false
    /// Nil hides the Delete button (Seerr wouldn't allow it).
    var onDelete: (() -> Void)?
    @State private var detail: MediaDetail?

    var body: some View {
        HStack(spacing: 24) {
            Group {
                if let route = request.route {
                    NavigationLink(value: route) { label }
                } else {
                    label
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if deleting {
                ProgressView()
            } else if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    // Stretch to the row's height so its panel matches the title's panel.
                    Label("Delete", systemImage: "trash")
                        .frame(maxHeight: .infinity)
                }
                // Grows more than the wide title panel so its lift is just as noticeable.
                .buttonStyle(ThemedButtonStyle(focusScale: 1.12))
                .fixedSize(horizontal: true, vertical: false)
                .zIndex(1) // draw over the title panel while enlarged
            }
        }
        // The row is as tall as the title panel; the Delete button fills that height.
        .fixedSize(horizontal: false, vertical: true)
        .task {
            if let route = request.route { detail = try? await app.api.detail(for: route) }
        }
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
                    if let status = request.media?.status {
                        StatusBadge(status: status)
                    }
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
