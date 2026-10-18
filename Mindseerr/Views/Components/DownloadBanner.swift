import SwiftUI

/// A banner for a download that just finished, shown over whatever screen the user is on. It can't be
/// focused, so it never takes the remote's focus away from what the user was doing.
struct DownloadBanner: View {
    @Environment(AppState.self) private var app
    @Environment(\.appTheme) private var theme
    let item: FinishedDownload

    @State private var detail: MediaDetail?

    var body: some View {
        HStack(spacing: 24) {
            PosterImage(url: TMDBImage.url(detail?.posterPath, size: .poster), title: item.title)
                .frame(width: 72, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Label("Download finished", systemImage: "checkmark.circle.fill")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(theme.highlight)
                Text(detail?.displayTitle ?? item.title)
                    .font(.headline)
                    .lineLimit(2)
                if let label = item.episodeLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 380, alignment: .leading)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(theme.highlight.opacity(0.6), lineWidth: 2))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .padding(.trailing, 60)
        .padding(.top, 140)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .task {
            if let route = item.route { detail = try? await app.api.detail(for: route) }
        }
    }
}
