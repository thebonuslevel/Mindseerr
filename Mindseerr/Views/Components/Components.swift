import SwiftUI

// MARK: - Poster

struct PosterImage: View {
    let url: URL?
    var title: String = ""

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    fallback
                case .empty:
                    if url == nil { fallback } else { Color.clear }
                @unknown default:
                    Color.clear
                }
            }
        }
        .clipped()
    }

    private var fallback: some View {
        VStack(spacing: 12) {
            Image(systemName: "film").font(.largeTitle)
            if !title.isEmpty {
                Text(title).font(.caption).multilineTextAlignment(.center).lineLimit(3)
            }
        }
        .foregroundStyle(.secondary)
        .padding()
    }
}

/// A focusable poster that opens the title, with its name and year underneath.
struct PosterCard: View {
    @Environment(AppState.self) private var app
    let item: MediaResult
    var width: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let route = item.route {
                NavigationLink(value: route) {
                    PosterImage(url: item.posterURL, title: item.displayTitle)
                        .frame(width: width, height: width * 1.5)
                        .overlay(alignment: .topTrailing) {
                            if let status = item.mediaInfo?.displayStatus {
                                StatusBadge(status: status).padding(10)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if let progress = app.downloads.progress(for: item.type, tmdbId: item.id,
                                                                    tvdbId: item.mediaInfo?.tvdbId) {
                                PosterProgressBar(progress: progress).padding(12)
                            }
                        }
                }
                .buttonStyle(.card)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.caption)
                    .lineLimit(1)
                Text([item.year, item.type == .tv ? String(localized: "Series") : String(localized: "Movie")].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A thin download progress bar laid over the bottom of a poster, in the theme's highlight color.
struct PosterProgressBar: View {
    @Environment(\.appTheme) private var theme
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.6))
                Capsule()
                    .fill(theme.highlight)
                    .frame(width: max(geo.size.width * min(max(progress, 0), 1), 8))
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Downloading, \(Int((progress * 100).rounded())) percent")
    }
}

struct PosterPlaceholder: View {
    var width: CGFloat = 240

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary)
            .frame(width: width, height: width * 1.5)
    }
}

// MARK: - Badges

struct Pill: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(color.opacity(0.9), in: Capsule())
    }
}

struct StatusBadge: View {
    let status: MediaStatus

    var body: some View {
        switch status {
        case .available: Pill(text: "Available", color: .green)
        case .partiallyAvailable: Pill(text: "Partial", color: .teal)
        case .processing: Pill(text: "Requested", color: .indigo)
        case .pending: Pill(text: "Pending", color: .orange)
        case .unknown, .deleted: EmptyView()
        }
    }
}

struct RequestStatusBadge: View {
    let status: RequestStatus

    var body: some View {
        switch status {
        case .pendingApproval: Pill(text: "Pending Approval", color: .orange)
        case .approved: Pill(text: "Approved", color: .indigo)
        case .declined: Pill(text: "Declined", color: .red)
        case .failed: Pill(text: "Failed", color: .red)
        case .completed: Pill(text: "Completed", color: .green)
        case .unknown: EmptyView()
        }
    }
}
