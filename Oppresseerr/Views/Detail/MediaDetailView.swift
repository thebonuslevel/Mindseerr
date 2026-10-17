import SwiftUI

struct MediaDetailView: View {
    @Environment(AppState.self) private var app
    let route: MediaRoute

    @State private var detail: MediaDetail?
    @State private var loadError: String?
    @State private var showSeasonPicker = false
    @State private var confirmMovieRequest = false
    @State private var isRequesting = false
    @State private var notice: Notice?

    private struct Notice {
        let title: String
        let message: String
    }

    var body: some View {
        ZStack {
            backdrop
            if let detail {
                content(detail)
            } else if let loadError {
                ContentUnavailableView("Couldn't Load", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .sheet(isPresented: $showSeasonPicker) {
            if let detail {
                SeasonPickerView(detail: detail) { seasons in
                    Task { await submit(seasons: seasons) }
                }
            }
        }
        .confirmationDialog("Request \(detail?.displayTitle ?? "this title")?",
                            isPresented: $confirmMovieRequest, titleVisibility: .visible) {
            Button("Request") { Task { await submit(seasons: nil) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(notice?.title ?? "", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        ), presenting: notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: - Layout

    private var backdrop: some View {
        GeometryReader { geo in
            AsyncImage(url: TMDBImage.url(detail?.backdropPath, size: .backdrop)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.black
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay {
                LinearGradient(colors: [.black.opacity(0.95), .black.opacity(0.65), .black.opacity(0.15)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private func content(_ detail: MediaDetail) -> some View {
        HStack(alignment: .top, spacing: 60) {
            PosterImage(url: TMDBImage.url(detail.posterPath, size: .posterLarge), title: detail.displayTitle)
                .frame(width: 360, height: 540)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 24)

            VStack(alignment: .leading, spacing: 22) {
                Text(detail.displayTitle)
                    .font(.largeTitle).bold()
                    .lineLimit(2)
                if let tagline = detail.tagline, !tagline.isEmpty {
                    Text(tagline)
                        .font(.headline).italic()
                        .foregroundStyle(.secondary)
                }
                Text(detail.metadataLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let status = detail.mediaInfo?.status {
                    StatusBadge(status: status)
                }
                downloadProgress(detail)
                if let overview = detail.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.body)
                        .lineLimit(7)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                actions(detail)
                    .padding(.top, 20)
            }
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One progress line per Sonarr/Radarr download for this title; Sonarr may be grabbing several episodes.
    @ViewBuilder
    private func downloadProgress(_ detail: MediaDetail) -> some View {
        let downloads = app.downloads.downloads(for: route.type, tmdbId: route.tmdbId,
                                                tvdbId: detail.mediaInfo?.tvdbId)
        if !downloads.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(downloads) { download in
                    DownloadProgressLine(download: download, barWidth: 520, showsService: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            // Frosted gray like the tab bar, so the text stays readable over bright backdrops.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder
    private func actions(_ detail: MediaDetail) -> some View {
        let availability = RequestAvailability(detail: detail, type: route.type)
        HStack(spacing: 30) {
            switch availability {
            case .requestable:
                Button {
                    if route.type == .tv { showSeasonPicker = true } else { confirmMovieRequest = true }
                } label: {
                    Label(route.type == .tv ? "Request Series" : "Request", systemImage: "plus.circle.fill")
                }
                .disabled(isRequesting)
            case .partiallyRequestable:
                Button {
                    showSeasonPicker = true
                } label: {
                    Label("Request More Seasons", systemImage: "plus.circle")
                }
                .disabled(isRequesting)
            case .requested:
                Label("Requested", systemImage: "clock.fill")
                    .foregroundStyle(.secondary)
            case .available:
                Label("Available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if isRequesting { ProgressView() }
        }
    }

    // MARK: - Actions

    private func load() async {
        do {
            detail = try await app.api.detail(for: route, useCache: false)
            loadError = nil
        } catch {
            if detail == nil { loadError = AppState.friendly(error) }
        }
    }

    private func submit(seasons: [Int]?) async {
        let title = detail?.displayTitle ?? "This title"
        isRequesting = true
        defer { isRequesting = false }
        do {
            let request = try await app.api.request(route, seasons: seasons)
            let message = request.status == .approved
                ? "\(title) was approved and is on its way."
                : "\(title) was sent and is waiting for approval."
            notice = Notice(title: "Requested", message: message)
            await load()
        } catch {
            notice = Notice(title: "Request Failed", message: AppState.friendly(error))
        }
    }
}

struct SeasonPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let detail: MediaDetail
    let onSubmit: ([Int]) -> Void
    @State private var selected: Set<Int>

    init(detail: MediaDetail, onSubmit: @escaping ([Int]) -> Void) {
        self.detail = detail
        self.onSubmit = onSubmit
        _selected = State(initialValue: Set(detail.requestableSeasonNumbers))
    }

    private var open: [Int] { detail.requestableSeasonNumbers }
    private var allSelected: Bool { !open.isEmpty && selected.count == open.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Request \(detail.displayTitle)")
                .font(.title2).bold()

            List {
                ForEach(detail.regularSeasons) { season in
                    row(season)
                }
            }

            HStack(spacing: 30) {
                Button {
                    let seasons = selected.sorted()
                    dismiss()
                    onSubmit(seasons)
                } label: {
                    Label(selected.count == 1 ? "Request 1 Season" : "Request \(selected.count) Seasons",
                          systemImage: "plus.circle.fill")
                }
                .disabled(selected.isEmpty)

                Button(allSelected ? "Deselect All" : "Select All") {
                    selected = allSelected ? [] : Set(open)
                }
                .disabled(open.isEmpty)

                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .themedBackground()
    }

    private func row(_ season: Season) -> some View {
        let number = season.seasonNumber
        let state = detail.state(ofSeason: number)
        let isOn = selected.contains(number)

        return Button {
            if isOn { selected.remove(number) } else { selected.insert(number) }
        } label: {
            HStack(spacing: 24) {
                Image(systemName: state != .notRequested ? "lock.fill" : (isOn ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(season.name ?? "Season \(number)")
                    if let count = season.episodeCount {
                        Text(count == 1 ? "1 episode" : "\(count) episodes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let label = state.label {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(state != .notRequested)
    }
}
