import SwiftUI
import UIKit

struct MediaDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.appTheme) private var theme
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var focusSpace
    let route: MediaRoute

    @State private var detail: MediaDetail?
    @State private var tomatoes: RottenTomatoesRating?
    @State private var showEpisodes = false
    @AppStorage(ExternalPlayer.storageKey) private var player: ExternalPlayer = .infuse
    @State private var playback: PlaybackSession?
    @State private var preparing = false
    @State private var loadError: String?
    /// The Radarr (movie) or Sonarr (series) servers in Seerr; decides whether 4K is offered.
    @State private var servers: [RequestServer] = []
    /// Set when the server list couldn't be read (an account without the rights to list servers can still have the
    /// 4K permission). 4K is then offered on the permission alone, and Seerr decides when the request is sent.
    @State private var serversUnreadable = false
    /// What this user may still request of this kind of title; nil until read, or if Seerr doesn't say.
    @State private var quota: RequestQuota.Limit?
    @State private var requestTarget: RequestTarget?
    @State private var confirmMovieRequest: RequestTarget?
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
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 50) {
                        header(detail)
                        rows(detail)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollClipDisabled()
                .focusScope(focusSpace)
            } else if let loadError {
                VStack(spacing: 30) {
                    ContentUnavailableView("Couldn't Load", systemImage: "exclamationmark.triangle",
                                           description: Text(loadError))
                    // Something focusable, so Menu goes back instead of leaving the app.
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .fullScreenCover(item: $playback) { session in
            NativePlayerView(session: session).ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showEpisodes) {
            if let detail { EpisodeListView(detail: detail, tmdbId: route.tmdbId) }
        }
        .task(id: detail?.mediaInfo?.tmdbId) {
            guard route.type == .tv, detail?.mediaInfo?.hasAnyCopy == true else { return }
            await app.resolutions.loadSeries(tmdbId: route.tmdbId, tvdbId: detail?.mediaInfo?.tvdbId, services: app.downloads.services)
        }
        .task { tomatoes = await app.api.rottenTomatoes(for: route) }
        .task { await loadQuota() }
        .task {
            do { servers = try await app.api.requestServers(for: route.type) } catch { serversUnreadable = true }
        }
        // Full screen: as a sheet, tvOS sizes it to its content and the season list collapses.
        .fullScreenCover(item: $requestTarget) { target in
            if let detail {
                RequestView(detail: detail, type: route.type, is4k: target.is4k,
                            showsOptions: canChooseOptions,
                            servers: servers.filter { $0.is4k == target.is4k }) { seasons, options in
                    Task { await submit(seasons: seasons, options: options) }
                }
            }
        }
        .confirmationDialog(confirmTitle,
                            isPresented: Binding(get: { confirmMovieRequest != nil },
                                                 set: { if !$0 { confirmMovieRequest = nil } }),
                            titleVisibility: .visible, presenting: confirmMovieRequest) { target in
            Button(target.is4k ? "Request in 4K" : "Request") {
                Task { await submit(seasons: nil, options: RequestOptions(is4k: target.is4k)) }
            }
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

    private var confirmTitle: String {
        let suffix = confirmMovieRequest?.is4k == true ? String(localized: " in 4K", comment: "Appended to a request title: the 4K copy") : ""
        return String(localized: "Request \(detail?.displayTitle ?? String(localized: "this title"))\(suffix)?")
    }

    private var canChooseOptions: Bool { app.user?.canChooseRequestOptions == true }

    /// 4K is offered when the user may request it and Seerr has a 4K server for this kind of title.
    private var offers4K: Bool {
        guard app.user?.canRequest4K(route.type) == true else { return false }
        return serversUnreadable || servers.contains(where: \.is4k)
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

    private func header(_ detail: MediaDetail) -> some View {
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
                if let tomatoes { RottenTomatoesScores(rating: tomatoes) }
                HStack(spacing: 12) {
                    if let status = detail.mediaInfo?.status {
                        StatusBadge(status: status)
                    }
                    // One 4K tag: from Seerr's 4K copy when it has one, else from the files in Radarr or Sonarr.
                    if offers4K, let status4k = detail.mediaInfo?.status4k, status4k != .unknown {
                        Pill(text: "4K", color: .purple)
                        StatusBadge(status: status4k)
                    } else if app.resolutions.is4K(type: route.type, tmdbId: route.tmdbId) {
                        Pill(text: "4K", color: .purple)
                    }
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
                    // The page opens on its buttons, not on the cast row further down.
                    .prefersDefaultFocus(true, in: focusSpace)
                if let note = quota?.summary(noun: route.type == .tv ? "series" : "movie") {
                    Label(note, systemImage: quota?.isExhausted == true ? "exclamationmark.circle" : "ticket")
                        .font(.callout)
                        .foregroundStyle(quota?.isExhausted == true ? Color.orange : Color.secondary)
                }
            }
        }
        .focusSection()
    }

    /// Cast, crew, and related titles, on a backdrop that darkens into the theme so they stay readable.
    @ViewBuilder
    private func rows(_ detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 40) {
            let cast = detail.cast
            if !cast.isEmpty {
                DetailRow(title: "Cast") {
                    ForEach(cast.prefix(30)) { member in
                        PersonCard(id: member.id, name: member.name, role: member.character, profilePath: member.profilePath)
                    }
                }
            }
            let crew = detail.keyCrew
            if !crew.isEmpty {
                DetailRow(title: "Crew") {
                    ForEach(crew) { person in
                        PersonCard(id: person.id, name: person.name, role: person.jobs.joined(separator: ", "),
                                   profilePath: person.profilePath)
                    }
                }
            }
            RelatedTitlesRow(title: "Recommended", list: .recommendations, route: route)
            RelatedTitlesRow(title: "Similar", list: .similar, route: route)
        }
        .padding(.top, 30)
        .background(alignment: .top) {
            LinearGradient(colors: [theme.background.opacity(0), theme.background.opacity(0.92)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12))
                .padding(.horizontal, -600)
                .padding(.bottom, -400)
        }
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
        HStack(spacing: 24) {
            // Available movies can be played in the chosen external player.
            if route.type == .movie, player.isOn, detail.mediaInfo?.hasAnyCopy == true {
                Button { play(detail) } label: {
                    Label(player.playLabel, systemImage: "play.circle.fill")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            // Series with something on the server open an episode list, each episode playing in the external player.
            if route.type == .tv, player.isOn,
               detail.mediaInfo?.hasAnyCopy == true {
                Button { showEpisodes = true } label: {
                    Label(player.playLabel, systemImage: "play.circle.fill")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            // A movie that's on the server only as a 4K copy doesn't also offer a standard request.
            if !(route.type == .movie && detail.mediaInfo?.hasAnyCopy == true) || detail.mediaInfo?.hasStandardCopy == true {
                requestButton(detail, is4k: false)
            }
            if offers4K {
                requestButton(detail, is4k: true)
            }
            if let trailer = detail.trailer {
                Button {
                    playTrailer(trailer)
                } label: {
                    Label("Trailer", systemImage: "play.fill")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            if isRequesting { ProgressView() }
        }
    }

    /// The request button for the standard or 4K copy, or its status once requested or available.
    @ViewBuilder
    private func requestButton(_ detail: MediaDetail, is4k: Bool) -> some View {
        let suffix = is4k ? String(localized: " in 4K", comment: "Appended to a request title: the 4K copy") : ""
        switch RequestAvailability(detail: detail, type: route.type, is4k: is4k) {
        case .requestable:
            Button {
                startRequest(is4k: is4k)
            } label: {
                Label(route.type == .tv ? "Request Series\(suffix)" : "Request Movie\(suffix)",
                      systemImage: "plus.circle.fill")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)   // stays on one line next to Play, Available and Trailer
            }
            .disabled(isRequesting || quota?.isExhausted == true)
        case .partiallyRequestable:
            Button {
                startRequest(is4k: is4k)
            } label: {
                Label("Request More Seasons\(suffix)", systemImage: "plus.circle")
            }
            .disabled(isRequesting || quota?.isExhausted == true)
        case .requested:
            FocusableStatus { Label(is4k ? "4K Requested" : "Requested", systemImage: "clock.fill").lineLimit(1).fixedSize(horizontal: true, vertical: false) }
        case .available:
            // Only the checkmark is green; the text follows the button colors so it stays readable when focused.
            FocusableStatus {
                Label { Text(is4k ? "4K Available" : "Available") } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - Actions

    /// Series always pick seasons; movies go straight to a confirmation unless the user may choose options.
    private func startRequest(is4k: Bool) {
        let target = RequestTarget(is4k: is4k)
        if route.type == .tv || canChooseOptions {
            requestTarget = target
        } else {
            confirmMovieRequest = target
        }
    }

    /// Hands the movie to the player chosen in Settings, and says so if that isn't possible or the app isn't installed.
    private func play(_ detail: MediaDetail) {
        if player == .native {
            guard !preparing else { return }
            preparing = true
            Task {
                defer { preparing = false }
                do {
                    playback = try await MediaServerPlayback.session(for: detail.mediaInfo, episode: nil, title: detail.displayTitle)
                } catch {
                    notice = Notice(title: String(localized: "Can't Play"), message: error.localizedDescription)
                }
            }
            return
        }
        guard let url = player.playURL(tmdbId: route.tmdbId) else {
            notice = Notice(title: String(localized: "Can't Open in \(player.name)"), message: String(localized: "\(player.name) couldn't be opened."))
            return
        }
        NSLog("Mindseerr play: opening %@", url.absoluteString)
        UIApplication.shared.open(url, options: [:]) { opened in
            NSLog("Mindseerr play: %@ -> %@", url.absoluteString, opened ? "opened" : "refused")
            guard !opened else { return }
            Task { @MainActor in
                notice = Notice(title: String(localized: "Can't Open \(player.name)"),
                                message: String(localized: "\(player.name) didn't open. Install it from the App Store on your Apple TV, then try again, or turn the Play button off in Settings → External Player."))
            }
        }
    }

    private func playTrailer(_ trailer: RelatedVideo) {
        guard let url = trailer.youTubeAppURL else { return }
        openURL(url) { opened in
            if !opened {
                notice = Notice(title: String(localized: "Can't Play Trailer"),
                                message: String(localized: "Trailers play in the YouTube app. Install YouTube from the App Store on your Apple TV, then try again."))
            }
        }
    }

    private func loadQuota() async {
        guard let id = app.user?.id else { return }
        quota = (try? await app.api.quota(forUser: id))?.limit(for: route.type)
    }

    private func load() async {
        do {
            let first = detail == nil
            detail = try await app.api.detail(for: route, useCache: false)
            loadError = nil
            // The page was empty when it appeared, so focus may have landed elsewhere: put it on the buttons.
            if first { resetFocus(in: focusSpace) }
        } catch {
            if detail == nil { loadError = AppState.friendly(error) }
        }
    }

    private func submit(seasons: [Int]?, options: RequestOptions) async {
        let title = (detail?.displayTitle ?? "This title") + (options.is4k ? String(localized: " in 4K", comment: "Appended to a request title: the 4K copy") : "")
        isRequesting = true
        defer { isRequesting = false }
        do {
            let request = try await app.api.request(route, seasons: seasons, options: options)
            let message = request.status == .approved
                ? "\(title) was approved and is on its way."
                : "\(title) was sent and is waiting for approval."
            notice = Notice(title: String(localized: "Requested"), message: message)
            await load()
            await loadQuota()
        } catch {
            notice = Notice(title: String(localized: "Request Failed"), message: AppState.friendly(error))
        }
    }
}

/// A status ("Requested", "Available") that can take focus, drawn with the themed cursor like other buttons.
/// Without anything focusable on the page, focus falls back to the tab bar, where Menu leaves the app
/// instead of going back. Selecting it does nothing.
private struct FocusableStatus<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Button {} label: { content }
    }
}
