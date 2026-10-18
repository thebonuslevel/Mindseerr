import SwiftUI

/// A banner for a download that just finished, shown over whatever screen the user is on. It can't be
/// focused, so it never takes the remote's focus away from what the user was doing.
struct DownloadBanner: View {
    @Environment(AppState.self) private var app
    @Environment(\.appTheme) private var theme
    let item: FinishedDownload

    @State private var detail: MediaDetail?

    private let corner: CGFloat = 46

    var body: some View {
        HStack(spacing: 18) {
            PosterImage(url: TMDBImage.url(detail?.posterPath, size: .poster), title: item.title)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                // Like an iOS or macOS notification: a small header line, then a bold title and a detail line.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Download finished").lineLimit(1)
                    Spacer(minLength: 6)
                    Text("now")
                }
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.85)

                Text(detail?.displayTitle ?? item.title)
                    .font(.callout).fontWeight(.semibold)
                    .lineLimit(2)
                Text(item.episodeLabel ?? "Ready to watch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(width: 600)
        // The theme's secondary (highlight) color, left see-through over a blur like system notifications.
        .background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(theme.highlight.opacity(0.32)))
        }
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 22, y: 8)
        // Tucked into the top right corner, clear of the tab bar in the middle.
        .padding(.trailing, 44)
        .padding(.top, 36)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .task {
            if let route = item.route { detail = try? await app.api.detail(for: route) }
        }
    }
}
