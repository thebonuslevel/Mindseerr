import SwiftUI

/// A titled, horizontally scrolling row on the detail page.
struct DetailRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3).fontWeight(.semibold)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    content
                }
                .padding(.vertical, 30) // room for the focus lift
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// A person in the Cast or Crew row: round photo, name, and their role. Selecting it opens their other work.
struct PersonCard: View {
    let id: Int
    let name: String
    let role: String?
    let profilePath: String?

    private let size: CGFloat = 170

    var body: some View {
        NavigationLink(value: PersonRoute(id: id, name: name, profilePath: profilePath)) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(.quaternary)
                    if let url = TMDBImage.url(profilePath, size: .profile) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    } else {
                        Text(initials)
                            .font(.title2).bold()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .circularHoverShape()
                .hoverEffect(.highlight)

                VStack(spacing: 4) {
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                    if let role, !role.isEmpty {
                        Text(role)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            // Take the height two lines need; the row would otherwise squeeze it to one.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: size + 50)
            }
        }
        .buttonStyle(.borderless)
        .buttonBorderShape(.circle)
        .accessibilityLabel([name, role].compactMap { $0 }.joined(separator: ", "))
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

/// "Recommended" or "Similar" titles for a movie or series, as a row of posters. Hidden when TMDB has none.
struct RelatedTitlesRow: View {
    @Environment(AppState.self) private var app
    let title: String
    let list: SeerrClient.RelatedList
    let route: MediaRoute

    @State private var items: [MediaResult] = []

    var body: some View {
        // A VStack, not a Group: an empty Group has nothing to attach the loading task to, so it never ran.
        VStack(alignment: .leading, spacing: 0) {
            if !items.isEmpty {
                DetailRow(title: title) {
                    ForEach(items, id: \.uid) { item in
                        PosterCard(item: item)
                    }
                }
            }
        }
        .task(id: route) {
            let results = (try? await app.api.related(list, to: route).results) ?? []
            // TMDB can list people or the title itself; keep other requestable titles.
            items = results.filter { $0.route != nil && $0.route != route }
        }
    }
}

private extension View {
    /// Makes the focus highlight round on tvOS 18 and later; tvOS 17 keeps the standard rounded card.
    @ViewBuilder
    func circularHoverShape() -> some View {
        if #available(tvOS 18.0, *) {
            contentShape(.hoverEffect, Circle())
        } else {
            self
        }
    }
}
