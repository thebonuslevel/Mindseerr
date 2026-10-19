import SwiftUI

@main
struct MindseerrApp: App {
    @State private var app = AppState()

    init() {
        // Posters are re-shown constantly while scrolling rows; give AsyncImage a bigger cache.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .gloam

    var body: some View {
        Group {
            switch app.phase {
            case .launching: LaunchView()
            case .serverSetup: ServerSetupView()
            case .signIn: SignInView()
            case .ready: MainTabView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground()
        // The theme also fixes light/dark, so the Apple TV's own appearance setting doesn't change the app.
        .appTheme(app.previewTheme ?? theme)
        .task { await app.bootstrap() }
    }
}

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @State private var section = AppSection.discover
    /// Changing this rebuilds Settings, so coming back to it shows its top level, scrolled to the top.
    @State private var settingsResetID = UUID()

    var body: some View {
        // The menu runs down the left edge, collapsed to logos and opening over the content while it has focus.
        // Only the selected section is built, so leaving one always returns to its top level.
        HStack(spacing: 0) {
            // The menu's column is always this wide; when it opens, the panel grows over the content beside it.
            Color.clear
                .frame(width: SideMenu.collapsedWidth)
                .overlay(alignment: .leading) { SideMenu(selection: $section) }
                .zIndex(1)

            Group {
                switch section {
                case .discover: DiscoverView()
                case .search: SearchView()
                case .watchlists: WatchlistsView()
                case .activity: ActivityView()
                case .settings: SettingsView().id(settingsResetID)
                }
            }
            .padding(.leading, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()
        }
        // The menu hugs the left edge of the screen instead of sitting inside the TV's safe-area margin.
        .ignoresSafeArea(.container, edges: .leading)
        .onChange(of: section) { oldSection, _ in
            if oldSection == .settings { settingsResetID = UUID() }
        }
        // Top Shelf links (mindseerr://media/movie/123) open the title on Discover.
        .onOpenURL { url in
            guard let link = TopShelfCache.parse(url), let type = MediaType(rawValue: link.type) else { return }
            section = .discover
            app.deepLinkRoute = MediaRoute(type: type, tmdbId: link.tmdbId)
        }
        // A finished download announces itself over whichever tab is showing, for a few seconds.
        .overlay {
            // Laid out against the whole screen (not the safe area) so the banner's margins match the tab bar's.
            ZStack(alignment: .topTrailing) {
                Color.clear
                if let finished = app.downloads.banner {
                    DownloadBanner(item: finished)
                        .id(finished.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .animation(.spring(duration: 0.4), value: app.downloads.banner?.id)
        .task(id: app.downloads.banner?.id) {
            guard app.downloads.banner != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { app.downloads.dismissBanner() }
        }
        // Keeps Sonarr/Radarr progress current on every tab; restarts when services change.
        .task(id: app.downloads.services) { await app.downloads.run(api: app.api) }
    }
}

extension View {
    /// Every tab's NavigationStack can open a movie or series.
    func mediaDestinations() -> some View {
        navigationDestination(for: MediaRoute.self) { route in
            MediaDetailView(route: route)
                .themedBackground()
        }
        .navigationDestination(for: PersonRoute.self) { person in
            PersonView(person: person)
                .themedBackground()
        }
    }
}
