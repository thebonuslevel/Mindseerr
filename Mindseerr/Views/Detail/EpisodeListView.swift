import SwiftUI
import UIKit

/// The episodes of a series, grouped by season, each one opening in the external player when selected.
struct EpisodeListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExternalPlayer.storageKey) private var player: ExternalPlayer = .infuse
    let detail: MediaDetail
    let tmdbId: Int

    @State private var seasons: [SeasonDetail] = []
    @State private var loading = true
    @State private var notice: String?
    @State private var playback: PlaybackSession?
    @State private var preparing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                    } else if seasons.isEmpty {
                        ContentUnavailableView("No Episodes Found", systemImage: "tv",
                                               description: Text("Seerr didn't list any episodes for \(detail.displayTitle)."))
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(seasons, id: \.seasonNumber) { season in
                        if let episodes = season.episodes, !episodes.isEmpty, let number = season.seasonNumber {
                            VStack(alignment: .leading, spacing: 18) {
                                Text("Season \(number)").font(.title2).fontWeight(.semibold)
                                ForEach(episodes) { episode in
                                    episodeRow(episode)
                                }
                            }
                            .focusSection()
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .themedBackground()
            .navigationTitle(detail.displayTitle)
        }
        .task { await load() }
        .fullScreenCover(item: $playback) { session in
            NativePlayerView(session: session).ignoresSafeArea()
        }
        .alert(player == .native ? String(localized: "Can't Play") : String(localized: "Can't Open \(player.name)"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func episodeRow(_ episode: Episode) -> some View {
        Button { play(episode) } label: {
            HStack(alignment: .top, spacing: 24) {
                Text("E\(episode.episodeNumber)")
                    .font(.headline).monospacedDigit()
                    .frame(width: 80, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        Text(episode.name ?? "Episode \(episode.episodeNumber)")
                            .font(.headline)
                            .lineLimit(1)
                        if let runtime = episode.runtime, runtime > 0 {
                            Text("\(runtime) min").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func play(_ episode: Episode) {
        if player == .native {
            guard !preparing else { return }
            preparing = true
            let title = "\(detail.displayTitle) · S\(episode.seasonNumber) E\(episode.episodeNumber)"
            Task {
                defer { preparing = false }
                do {
                    playback = try await MediaServerPlayback.session(
                        for: detail.mediaInfo, episode: .init(season: episode.seasonNumber, number: episode.episodeNumber), title: title)
                } catch {
                    notice = error.localizedDescription
                }
            }
            return
        }
        guard let url = player.episodeURL(seriesTmdbId: tmdbId, season: episode.seasonNumber, episode: episode.episodeNumber) else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            Task { @MainActor in
                notice = String(localized: "\(player.name) didn't open. Install it from the App Store on your Apple TV, then try again, or turn the Play button off in Settings → External Player.")
            }
        }
    }

    /// Reads every season that's on the server (all of them if Seerr doesn't say which), in order.
    private func load() async {
        let onServer = Set((detail.mediaInfo?.seasons ?? [])
            .filter(\.onServer).map(\.seasonNumber))
        let numbers = detail.regularSeasons.map(\.seasonNumber).filter { onServer.isEmpty || onServer.contains($0) }.sorted()
        let api = app.api
        let id = tmdbId
        let loaded = await boundedMap(numbers, limit: 4) { number in try? await api.season(number, ofSeries: id) }
        seasons = loaded.compactMap { $0 }
        loading = false
    }
}
