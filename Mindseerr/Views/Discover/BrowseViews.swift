import SwiftUI

/// The Browse section: a row for each of movie genres, series genres, studios and networks, like the rows of Discover.
/// A row's title opens all of it as a grid.
struct BrowseView: View {
    @State private var path = NavigationPath()
    /// One model per kind, shared by its row and its full-screen grid.
    @State private var models = Dictionary(uniqueKeysWithValues: BrowseKind.allCases.map { ($0, BrowseListModel(kind: $0)) })

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    ForEach(BrowseKind.allCases) { kind in
                        if let model = models[kind] {
                            // The grid is pushed on the navigation path like a title is (a separate `isPresented`
                            // destination left it on screen when a title was opened from inside it).
                            BrowseSectionRow(model: model) { path.append(kind) }
                        }
                    }
                }
                .padding(.vertical, 30)
            }
            .themedBackground()
            .mediaDestinations()
            .navigationDestination(for: BrowseKind.self) { kind in
                if let model = models[kind] { BrowseListView(model: model) }
            }
        }
        // Leaving the section pops back to its rows, so coming back shows the top level.
        .onDisappear { path = NavigationPath() }
    }
}

/// The genres, studios or networks of one kind, loaded once and shared by its row and its full-screen grid.
@MainActor
@Observable
final class BrowseListModel {
    let kind: BrowseKind
    private(set) var targets: [BrowseTarget] = []
    /// TMDB logo paths for studios and networks, by id, as they arrive.
    private(set) var logos: [Int: String] = [:]
    /// A backdrop path for each genre's card, by id.
    private(set) var backdrops: [Int: String] = [:]
    private(set) var loading = true
    private(set) var error: String?
    @ObservationIgnored private var started = false

    init(kind: BrowseKind) { self.kind = kind }

    func load(using api: SeerrClient) async {
        guard !started else { return }
        started = true
        switch kind {
        case .studios:
            targets = KnownCompanies.studios.map { BrowseTarget(type: .movie, filter: .studio, id: $0.id, name: $0.name) }
        case .networks:
            targets = KnownCompanies.networks.map { BrowseTarget(type: .tv, filter: .network, id: $0.id, name: $0.name) }
        case .movieGenres, .tvGenres:
            do {
                let type = kind.mediaType
                let genres = try await api.genres(for: type)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                for genre in genres { if let path = GenreStyle.backdrop(from: genre.backdrops) { backdrops[genre.id] = path } }
                targets = genres.map { BrowseTarget(type: type, filter: .genre, id: $0.id, name: $0.name) }
            } catch {
                self.error = AppState.friendly(error)
                started = false
            }
        }
        loading = false
        // Studios and networks show their logos. The ones Seerr has already named are used at once; the rest are asked
        // for one company at a time.
        if kind == .studios || kind == .networks {
            for target in targets { if let known = LogoCache.path(for: target) { logos[target.id] = known } }
            let found = await boundedMap(targets, limit: 6) { target in (target.id, await api.companyLogo(for: target)) }
            for (id, path) in found { if let path { logos[id] = path } }
        }
    }
}

/// One tile of a row or grid: a genre's name, or a studio or network's logo.
private struct BrowseTile: View {
    let target: BrowseTarget
    let logo: String?
    var backdrop: String?

    var body: some View {
        if target.filter == .genre {
            NavigationLink(value: target) {
                GenreCard(target: target, backdrop: backdrop)
            }
            .buttonStyle(.card)
            .accessibilityLabel(target.name)
        } else {
            NavigationLink(value: target) {
                CompanyTile(name: target.name, logoPath: logo, treatment: KnownCompanies.treatedLogos[target.id])
            }
            .accessibilityLabel(target.name)
        }
    }
}

/// A genre as a card: one of its backdrops tinted in the genre's own two colors, with the name over it.
private struct GenreCard: View {
    let target: BrowseTarget
    let backdrop: String?

    var body: some View {
        let tone = GenreStyle.tone(for: target.id)
        ZStack {
            LinearGradient(colors: [Color(hex: UInt32(tone.dark, radix: 16) ?? 0x1F2937), Color(hex: UInt32(tone.light, radix: 16) ?? 0xD1D5DB).opacity(0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let backdrop, let url = GenreStyle.imageURL(path: backdrop, genreID: target.id) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
            Text(target.name)
                .font(.title3).fontWeight(.heavy)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                .padding(.horizontal, 16)
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A Browse row: the title (select it to open the whole list as a grid) over a row of tiles.
struct BrowseSectionRow: View {
    @Environment(AppState.self) private var app
    let model: BrowseListModel
    let onExpand: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onExpand) {
                HStack(spacing: 16) {
                    Text(model.kind.title)
                        .font(.title3).fontWeight(.semibold)
                    if titleFocused {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(ThemedButtonStyle(idleFill: false))
            .focused($titleFocused)
            .animation(.easeOut(duration: 0.15), value: titleFocused)

            if let error = model.error {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .center, spacing: 30) {
                        if model.loading {
                            ProgressView().padding(.horizontal, 60)
                        }
                        ForEach(model.targets, id: \.self) { target in
                            BrowseTile(target: target, logo: model.logos[target.id], backdrop: model.backdrops[target.id])
                                .frame(width: model.kind == .movieGenres || model.kind == .tvGenres ? 340 : 340)
                        }
                    }
                    .padding(.vertical, 30) // room for the focus lift
                }
                .scrollClipDisabled()
            }
        }
        .focusSection()
        .task { await model.load(using: app.api) }
    }
}

/// All the genres, studios or networks of one kind, as a grid.
struct BrowseListView: View {
    @Environment(AppState.self) private var app
    let model: BrowseListModel

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 380), spacing: 30, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text(model.kind.title).font(.title3).fontWeight(.semibold)
                if model.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if let error = model.error {
                    ContentUnavailableView("Couldn't Load \(model.kind.title)", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                        ForEach(model.targets, id: \.self) { target in
                            BrowseTile(target: target, logo: model.logos[target.id], backdrop: model.backdrops[target.id])
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .themedBackground()
        .task { await model.load(using: app.api) }
    }
}

/// A studio or network as its logo in white (dark while focused, so it shows on the highlight), or its name until
/// the logo arrives or if there isn't one.
private struct CompanyTile: View {
    @Environment(\.isFocused) private var focused
    @Environment(\.appTheme) private var theme
    let name: String
    let logoPath: String?
    /// For a logo that doesn't whiten well as it is: how to draw it in white instead.
    var treatment: LogoTreatment?

    /// White on a dark theme and dark on a light one, flipping while focused (the highlight is the opposite shade).
    private var darkLogo: Bool { focused != (theme.colorScheme == .light) }

    var body: some View {
        Group {
            if let treatment, let url = TMDBImage.url(logoPath, size: .logo) {
                TreatedLogo(url: url, name: name, treatment: treatment)
                    .brightness(darkLogo ? -1 : 0)
            } else if let url = TMDBImage.url(logoPath, size: .logo) {
                CachedLogo(url: url, name: name)
                    // Whatever colours the logo has, every visible pixel becomes white (or black when focused).
                    .saturation(0)
                    .brightness(darkLogo ? -1 : 1)
            } else {
                Text(name).lineLimit(1)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        // The button adds 16 above and below, so this makes it as tall as a genre card (190).
        .frame(height: 158)
    }
}

@MainActor
@Observable
private final class BrowseModel {
    let target: BrowseTarget
    private(set) var items: [MediaResult] = []
    private(set) var error: String?
    private(set) var loading = false
    var sort: BrowseSort = .popular {
        didSet { if sort != oldValue { reset() } }
    }

    @ObservationIgnored private var page = 0
    @ObservationIgnored private var totalPages = 1
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var generation = 0

    init(target: BrowseTarget) { self.target = target }

    private func reset() {
        generation += 1
        items = []
        page = 0
        totalPages = 1
        seen = []
        error = nil
        loading = false
    }

    func loadMore(using api: SeerrClient) async {
        guard !loading, page < totalPages else { return }
        loading = true
        let mine = generation
        defer { if mine == generation { loading = false } }
        do {
            let response = try await api.browse(target, sort: sort, page: page + 1)
            // The order was changed while this was loading: its answer is for the old order.
            guard mine == generation else { return }
            page = response.page
            totalPages = response.totalPages
            items += response.results.filter { $0.route != nil && seen.insert($0.uid).inserted }
            error = nil
        } catch {
            if mine == generation, items.isEmpty { self.error = AppState.friendly(error) }
        }
    }
}

/// The titles in one genre, studio or network, with the order switchable from its heading.
struct BrowseResultsView: View {
    @Environment(AppState.self) private var app
    @State private var model: BrowseModel
    @FocusState private var sortFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 260), spacing: 40, alignment: .top)]

    init(target: BrowseTarget) {
        _model = State(initialValue: BrowseModel(target: target))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                // The heading is the control: selecting it moves to the next order.
                Button { model.sort = model.sort.next } label: {
                    HStack(spacing: 16) {
                        Text(model.target.heading).font(.title3).fontWeight(.semibold)
                        Text("·").foregroundStyle(.secondary)
                        Text(model.sort.title).font(.title3).foregroundStyle(.secondary)
                        if sortFocused {
                            Label("Change order", systemImage: "arrow.up.arrow.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(ThemedButtonStyle(idleFill: false))
                .focused($sortFocused)
                .animation(.easeOut(duration: 0.15), value: sortFocused)

                if let error = model.error, model.items.isEmpty {
                    ContentUnavailableView("Couldn't Load Titles", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if model.items.isEmpty {
                    if model.loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
                    else { ContentUnavailableView("Nothing Here", systemImage: "film") }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                        ForEach(model.items, id: \.uid) { item in
                            PosterCard(item: item)
                                .onAppear {
                                    if item.uid == model.items.last?.uid {
                                        Task { await model.loadMore(using: app.api) }
                                    }
                                }
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .themedBackground()
        .task(id: model.sort) {
            if model.items.isEmpty { await model.loadMore(using: app.api) }
        }
    }
}

enum LogoTreatment: Sendable {
    /// Cut away a coloured box behind the lettering (Marvel's), leaving the lettering white.
    case cutBox
    /// Keep the artwork's light and dark as white and see-through (Warner Bros.' shield, MGM's lion).
    case shaded
}

/// A logo image from the cache folder (downloaded once, then kept), or the company's name until it's there.
private struct CachedLogo: View {
    let url: URL
    let name: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text(name).lineLimit(1).opacity(failed ? 1 : 0)
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            guard let data = await LogoCache.imageData(for: url), let loaded = UIImage(data: data) else { failed = true; return }
            image = loaded
        }
    }
}

/// A logo drawn in white by reading its pixels once it has downloaded.
private struct TreatedLogo: View {
    let url: URL
    let name: String
    let treatment: LogoTreatment
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text(name).lineLimit(1).opacity(failed ? 1 : 0)
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            if let cached = LogoMask.cache.object(forKey: url as NSURL) { image = cached; return }
            guard let data = await LogoCache.imageData(for: url),
                  let made = LogoMask.make(from: data, treatment: treatment) else { failed = true; return }
            LogoMask.cache.setObject(made, forKey: url as NSURL)
            image = made
        }
    }
}

enum LogoMask {
    nonisolated(unsafe) static let cache = NSCache<NSURL, UIImage>()

    /// White artwork at a see-through level worked out from each pixel's colour: for `.cutBox` the more a pixel leans
    /// red the more transparent it becomes, for `.shaded` the darker it is the more transparent it becomes.
    static func make(from data: Data, treatment: LogoTreatment) -> UIImage? {
        guard let source = UIImage(data: data)?.cgImage else { return nil }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            // Premultiplied: undo it to read the real colour.
            let r = alpha > 0 ? Double(pixels[i]) / 255 / alpha : 0
            let g = alpha > 0 ? Double(pixels[i + 1]) / 255 / alpha : 0
            let b = alpha > 0 ? Double(pixels[i + 2]) / 255 / alpha : 0
            let keep: Double
            switch treatment {
            case .cutBox:
                keep = 1 - min(max((r - (g + b) / 2) * 2, 0), 1)
            case .shaded:
                let luminance = 0.299 * r + 0.587 * g + 0.114 * b
                keep = min(max((luminance - 0.12) * 1.6, 0), 1)
            }
            let out = UInt8(max(0, min(255, alpha * keep * 255)))
            pixels[i] = out; pixels[i + 1] = out; pixels[i + 2] = out; pixels[i + 3] = out   // white at that alpha, premultiplied
        }
        guard let result = context.makeImage() else { return nil }
        return UIImage(cgImage: result)
    }
}
