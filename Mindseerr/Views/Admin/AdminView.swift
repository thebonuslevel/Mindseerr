import SwiftUI

/// Request management for admins and users with the Manage Requests permission:
/// approve or decline pending requests, retry failed ones, and delete requests.
struct AdminView: View {
    @Environment(AppState.self) private var app
    @State private var filter: SeerrClient.RequestFilter = .pending
    @State private var requests: [MediaRequest] = []
    @State private var counts: RequestCounts?
    @State private var page = 0
    @State private var totalPages = 1
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var error: String?
    @State private var busyIDs: Set<Int> = []
    @State private var approveAllProgress: String?
    @State private var confirmApproveAll = false
    @State private var notice: String?

    // Sonarr / Radarr (the services and queues live in app.downloads)
    /// Approved requests that aren't available yet, for matching downloads to who asked for them.
    @State private var trackedRequests: [MediaRequest] = []
    /// False until the requests have been read, so downloads aren't judged against an empty list.
    @State private var trackedLoaded = false
    @State private var showAddService = false
    @State private var serviceToRemove: ArrService?
    @State private var pendingDelete: MediaRequest?
    @State private var downloadToCancel: ArrDownload?
    @State private var path = NavigationPath()

    private let pageSize = 20

    private var monitor: DownloadMonitor { app.downloads }
    private var services: [ArrService] { monitor.services }
    private var downloads: [ArrDownload] { monitor.downloads }
    private var serviceErrors: [UUID: String] { monitor.errors }

    /// Only the downloads that belong to a Seerr request. Anything else in the queues (titles added straight
    /// to Sonarr, Radarr or qBittorrent) has no request to show it against, so it's left out.
    private var linkedDownloads: [ArrDownload] { downloads.filter { request(for: $0) != nil } }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    countsRow
                    servicesSection
                    if !services.isEmpty { downloadsSection }

                    HStack(spacing: 30) {
                        Picker("Show", selection: $filter) {
                            ForEach(SeerrClient.RequestFilter.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 1100)

                        if filter == .pending, !requests.isEmpty {
                            Button {
                                confirmApproveAll = true
                            } label: {
                                Label("Approve All", systemImage: "checkmark.circle.fill")
                            }
                            .disabled(approveAllProgress != nil)
                        }
                    }
                    .focusSection()

                    if let approveAllProgress {
                        HStack(spacing: 16) {
                            ProgressView()
                            Text(approveAllProgress).foregroundStyle(.secondary)
                        }
                    }

                    content
                }
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .themedBackground()
            .mediaDestinations()
        }
        .task(id: filter) { await reload() }
        // Pop back to the request list when leaving the tab, so returning always shows the top level.
        .onDisappear { path = NavigationPath() }
        // Look up who requested what whenever a new download shows up.
        .task(id: downloads.map(\.id)) { await loadTrackedRequests() }
        .sheet(isPresented: $showAddService) {
            AddArrServiceView { service in monitor.add(service) }
        }
        .confirmationDialog("Remove \(serviceToRemove?.name ?? "this service")?",
                            isPresented: Binding(get: { serviceToRemove != nil },
                                                 set: { if !$0 { serviceToRemove = nil } }),
                            titleVisibility: .visible,
                            presenting: serviceToRemove) { service in
            Button("Remove", role: .destructive) { monitor.remove(service) }
            Button("Cancel", role: .cancel) {}
        } message: { service in
            Text("Mindseerr stops showing downloads from \(service.name). Nothing changes on the \(service.kind.name) server.")
        }
        .confirmationDialog("Delete this request?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { request in
            Button("Delete Request", role: .destructive) {
                act(on: request, removeWhenDone: true) { try await $0.deleteRequest(id: request.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the request from Seerr. Anything already downloaded stays on your server.")
        }
        .confirmationDialog("Cancel this download?",
                            isPresented: Binding(get: { downloadToCancel != nil },
                                                 set: { if !$0 { downloadToCancel = nil } }),
                            titleVisibility: .visible,
                            presenting: downloadToCancel) { download in
            Button("Cancel Download", role: .destructive) { cancel(download) }
            Button("Keep Downloading", role: .cancel) {}
        } message: { download in
            Text("This removes \(download.title) from \(download.serviceName)'s queue and deletes the partial download from your download client. The request stays in Seerr.")
        }
        .confirmationDialog(approveAllTitle, isPresented: $confirmApproveAll, titleVisibility: .visible) {
            Button("Approve All") { approveAll() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Requests", isPresented: Binding(get: { notice != nil },
                                                set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func cancel(_ download: ArrDownload) {
        Task {
            do { try await monitor.cancel(download) } catch { notice = AppState.friendly(error) }
        }
    }

    private var approveAllTitle: String {
        let n = counts?.pending ?? requests.count
        return n == 1 ? "Approve 1 pending request?" : "Approve all \(n) pending requests?"
    }

    // MARK: - Pieces

    private var countsRow: some View {
        HStack(spacing: 70) {
            stat(counts?.pending, "Pending", .orange)
            stat(counts?.processing, "Processing", .indigo)
            stat(counts?.available, "Available", .green)
            stat(counts?.declined, "Declined", .red)
            stat(counts?.total, "Total", .secondary)
        }
        .monospacedDigit()
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Download Services")
                .font(.title3).fontWeight(.semibold)
            HStack(spacing: 24) {
                // Selecting a connected service offers to remove it.
                ForEach(services) { service in
                    Button { serviceToRemove = service } label: {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(serviceErrors[service.id] == nil ? Color.green : Color.red)
                                .frame(width: 14, height: 14)
                            Text(service.name)
                            if service.name != service.kind.name {
                                Text(service.kind.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button { showAddService = true } label: {
                    Label("Add Download Service", systemImage: "plus")
                }
            }
            ForEach(services.filter { serviceErrors[$0.id] != nil }) { service in
                Text("\(service.name): \(serviceErrors[service.id] ?? "")")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 1400, alignment: .leading)
            }
        }
        .focusSection()
    }

    private var downloadsSection: some View {
        let linked = linkedDownloads
        let hidden = downloads.count - linked.count
        return VStack(alignment: .leading, spacing: 20) {
            Text(linked.isEmpty ? "Active Downloads" : "Active Downloads (\(linked.count))")
                .font(.title3).fontWeight(.semibold)
            if !monitor.loaded || (!downloads.isEmpty && !trackedLoaded) {
                ProgressView()
            } else if linked.isEmpty {
                Text(serviceErrors.count == services.count
                     ? "Couldn't read any download queues."
                     : "Nothing is downloading for a Seerr request right now.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(linked) { download in
                        DownloadRow(download: download, request: request(for: download),
                                    onCancel: { downloadToCancel = download })
                    }
                }
            }
            if hidden > 0, trackedLoaded {
                Text(hidden == 1 ? "1 other download isn't linked to a Seerr request and is hidden."
                                 : "\(hidden) other downloads aren't linked to a Seerr request and are hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .focusSection()
    }

    private func stat(_ value: Int?, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.map(String.init) ?? "–")
                .font(.title2).bold()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if requests.isEmpty {
            if !loadedOnce || loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else if let error {
                ContentUnavailableView("Couldn't Load Requests", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                    .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(filter == .pending ? "Nothing Waiting" : "No Requests",
                                       systemImage: "checkmark.circle",
                                       description: Text(filter == .pending
                                            ? "There are no requests waiting for approval."
                                            : "No requests match this filter."))
                    .frame(maxWidth: .infinity)
            }
        } else {
            LazyVStack(spacing: 24) {
                ForEach(requests) { request in
                    AdminRequestRow(
                        request: request,
                        busy: busyIDs.contains(request.id),
                        download: downloads.first { $0.matches(request.media) },
                        onApprove: {
                            act(on: request, removeWhenDone: filter == .pending) { _ = try await $0.approve(requestID: request.id) }
                        },
                        onDecline: {
                            act(on: request, removeWhenDone: filter == .pending) { _ = try await $0.decline(requestID: request.id) }
                        },
                        onRetry: {
                            act(on: request, removeWhenDone: filter == .failed) { _ = try await $0.retry(requestID: request.id) }
                        },
                        onDelete: { pendingDelete = request }
                    )
                    .onAppear {
                        if request.id == requests.last?.id { Task { await loadMore() } }
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func reload() async {
        loading = true
        defer { loading = false; loadedOnce = true }
        do {
            let response = try await app.api.allRequests(filter: filter, skip: 0, take: pageSize)
            requests = response.results
            page = 1
            totalPages = response.pageInfo.pages
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            requests = []
            self.error = AppState.friendly(error)
        }
        await loadCounts()
    }

    private func loadMore() async {
        guard !loading, page < totalPages else { return }
        loading = true
        defer { loading = false }
        do {
            let response = try await app.api.allRequests(filter: filter, skip: page * pageSize, take: pageSize)
            let known = Set(requests.map(\.id))
            requests += response.results.filter { !known.contains($0.id) }
            page += 1
            totalPages = response.pageInfo.pages
        } catch {
            // Keep what's shown; scrolling to the end again retries.
        }
    }

    private func loadCounts() async {
        if let fresh = try? await app.api.requestCounts() { counts = fresh }
    }

    // MARK: - Downloads

    /// Reads the requests that downloads are matched against: the ones still being fetched, plus the most
    /// recent of all, so a download for a title that's already partly available still finds its request.
    private func loadTrackedRequests() async {
        guard !downloads.isEmpty else { return }
        async let processing = try? await app.api.allRequests(filter: .processing, skip: 0, take: 100)
        async let recent = try? await app.api.allRequests(filter: .all, skip: 0, take: 100)
        let (first, second) = await (processing, recent)
        guard first != nil || second != nil else { return }
        var seen = Set<Int>()
        trackedRequests = ((first?.results ?? []) + (second?.results ?? [])).filter { seen.insert($0.id).inserted }
        trackedLoaded = true
    }

    private func request(for download: ArrDownload) -> MediaRequest? {
        trackedRequests.first { download.matches($0.media) } ?? requests.first { download.matches($0.media) }
    }

    // MARK: - Actions

    private func act(on request: MediaRequest, removeWhenDone: Bool,
                     _ action: @escaping (SeerrClient) async throws -> Void) {
        let id = request.id
        Task {
            busyIDs.insert(id)
            defer { busyIDs.remove(id) }
            do {
                try await action(app.api)
                if removeWhenDone {
                    requests.removeAll { $0.id == id }
                } else {
                    await reload()
                }
                await loadCounts()
            } catch {
                notice = AppState.friendly(error)
            }
        }
    }

    private func approveAll() {
        Task {
            approveAllProgress = "Finding pending requests…"
            var ids: [Int] = []
            do {
                var skip = 0
                while true {
                    let response = try await app.api.allRequests(filter: .pending, skip: skip, take: 50)
                    ids += response.results.map(\.id)
                    skip += response.results.count
                    if response.results.isEmpty || skip >= response.pageInfo.results { break }
                }
            } catch {
                approveAllProgress = nil
                notice = AppState.friendly(error)
                return
            }

            var failed = 0
            var firstError: String?
            for (index, id) in ids.enumerated() {
                approveAllProgress = "Approving \(index + 1) of \(ids.count)…"
                do {
                    try await app.api.approve(requestID: id)
                } catch {
                    failed += 1
                    if firstError == nil { firstError = AppState.friendly(error) }
                }
            }
            approveAllProgress = nil
            let approved = ids.count - failed
            notice = failed == 0
                ? (approved == 1 ? "Approved 1 request." : "Approved \(approved) requests.")
                : "Approved \(approved) of \(ids.count). \(firstError ?? "")"
            await reload()
        }
    }
}

// MARK: - Row

struct AdminRequestRow: View {
    @Environment(AppState.self) private var app
    let request: MediaRequest
    let busy: Bool
    /// The Sonarr/Radarr download for this request's title, if one is in a queue (shows a Downloading tag).
    var download: ArrDownload?
    let onApprove: () -> Void
    let onDecline: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    @State private var detail: MediaDetail?

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            PosterImage(url: TMDBImage.url(detail?.posterPath, size: .poster))
                .frame(width: 100, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Text(detail?.displayTitle ?? "Loading…")
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(requester)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    RequestStatusBadge(status: request.status)
                    if let status = request.secondaryMediaStatus { StatusBadge(status: status) }
                    // In a Sonarr/Radarr queue right now: its actual state. Progress is in Active Downloads above.
                    if let download { DownloadPhaseBadge(phase: download.phase) }
                }

                // Actions get their own line so none is pushed off the row's edge.
                HStack(spacing: 20) {
                    switch request.status {
                    case .pendingApproval:
                        Button(action: onApprove) { Label("Approve", systemImage: "checkmark") }
                        Button(action: onDecline) { Label("Decline", systemImage: "xmark") }
                    case .failed:
                        Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") }
                    default:
                        EmptyView()
                    }
                    if let route = request.route {
                        NavigationLink(value: route) { Label("Details", systemImage: "info.circle") }
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    if busy { ProgressView() }
                }
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .disabled(busy)
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .focusSection()
        .task {
            if let route = request.route { detail = try? await app.api.detail(for: route) }
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
                parts.append(seasons.count == 1 ? "Season \(list)" : "Seasons \(list)")
            }
        } else {
            parts.append("Movie")
        }
        if let year = detail?.year { parts.append(year) }
        if request.is4k == true { parts.append("4K") }
        return parts.joined(separator: "  ·  ")
    }

    private var requester: String {
        var text = "Requested by \(request.requestedBy?.name ?? "someone")"
        if let date = request.createdDateText { text += " on \(date)" }
        return text
    }
}
