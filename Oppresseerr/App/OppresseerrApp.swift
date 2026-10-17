import SwiftUI

@main
struct OppresseerrApp: App {
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
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .abyss

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

    var body: some View {
        // Text-only titles so tvOS shows every section's name instead of condensing tabs to icons.
        TabView {
            DiscoverView()
                .tabItem { Text("Discover") }
            SearchView()
                .tabItem { Text("Search") }
            WatchlistsView()
                .tabItem { Text("Watchlists") }
            RequestsView()
                .tabItem { Text("Requests") }
            if app.user?.canManageRequests == true {
                AdminView()
                    .tabItem { Text("Admin") }
            }
            SettingsView()
                .tabItem { Text("Settings") }
        }
        // Brand mark in the top-right corner, level with the tab bar. Purely decorative.
        .overlay(alignment: .topTrailing) {
            Image("CthulhuMark")
                .resizable()
                .scaledToFit()
                .frame(height: 80)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // Keeps Sonarr/Radarr progress current on every tab; restarts when services change.
        .task(id: app.downloads.services) { await app.downloads.run() }
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
