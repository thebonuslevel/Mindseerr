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
    @State private var tab = Tab.discover
    /// Changing this rebuilds Settings, so coming back to the tab shows its top level, scrolled to the top.
    @State private var settingsResetID = UUID()

    private enum Tab: Hashable { case discover, search, watchlists, activity, settings }

    // The Settings page shows the logo itself (it opens the About page), so the tab bar's stays hidden.
    private var showsLogo: Bool { false }

    var body: some View {
        // Text-only titles so tvOS shows every section's name instead of condensing tabs to icons.
        // Each tab installs the logo in the tab bar's trailing edge, so it slides away with the bar
        // instead of floating over scrolled content. It's only shown on the Settings tab.
        TabView(selection: $tab) {
            DiscoverView()
                .tabBarLogo(visible: showsLogo)
                .tabItem { Text("Discover") }
                .tag(Tab.discover)
            SearchView()
                .tabBarLogo(visible: showsLogo)
                .tabItem { Text("Search") }
                .tag(Tab.search)
            WatchlistsView()
                .tabBarLogo(visible: showsLogo)
                .tabItem { Text("Watchlists") }
                .tag(Tab.watchlists)
            ActivityView()
                .tabBarLogo(visible: showsLogo)
                .tabItem { Text("Activity") }
                .tag(Tab.activity)
            SettingsView()
                .id(settingsResetID)
                .tabBarLogo(visible: showsLogo)
                .tabItem { Text("Settings") }
                .tag(Tab.settings)
        }
        // Leaving Settings resets it, so it's back at its top level when you return.
        .onChange(of: tab) { oldTab, _ in
            if oldTab == .settings { settingsResetID = UUID() }
        }
        // Top Shelf links (mindseerr://media/movie/123) open the title on Discover.
        .onOpenURL { url in
            guard let link = TopShelfCache.parse(url), let type = MediaType(rawValue: link.type) else { return }
            tab = .discover
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
    }
}
