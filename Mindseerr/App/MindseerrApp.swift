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
        // Top Shelf links (mindseerr://media/movie/123). Handled here, not on the main screen, so a link that
        // arrives while the app is still launching or signing in isn't lost.
        .onOpenURL { url in
            guard let link = TopShelfCache.parse(url), let type = MediaType(rawValue: link.type) else { return }
            app.incomingLink = MediaRoute(type: type, tmdbId: link.tmdbId)
        }
    }
}

private struct PageFocusSpaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// The focus namespace the menu resets into, so a page can name the control that should take the cursor.
    var pageFocusSpace: Namespace.ID? {
        get { self[PageFocusSpaceKey.self] }
        set { self[PageFocusSpaceKey.self] = newValue }
    }
}

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @State private var section = AppSection.discover
    /// Changing this rebuilds Settings, so coming back to it shows its top level, scrolled to the top.
    @State private var settingsResetID = UUID()
    /// Changing this rebuilds whichever page is showing, sending it back to its top level (selecting its menu item again).
    @State private var pageResetID = UUID()
    @Namespace private var focusSpace
    @Environment(\.resetFocus) private var resetFocus

    var body: some View {
        // The menu runs down the left edge, collapsed to logos and opening over the content while it has focus.
        // Only the selected section is built, so leaving one always returns to its top level.
        ZStack(alignment: .leading) {
            // Each page runs the full width, underneath the (transparent) collapsed menu, with only its scrolling
            // content inset to clear the menu. That way a focused row or title that reaches past the page's margin
            // isn't cut off at a column edge.
            Group {
                switch section {
                case .discover: DiscoverView()
                case .search: SearchView()
                case .watchlists: WatchlistsView()
                case .activity: ActivityView()
                case .settings: SettingsView().id(settingsResetID)
                }
            }
            .id(pageResetID)
            // Settings is a List, which only applies this margin some of the time (its rows jump left and its section
            // headers appear and vanish as it scrolls), so it clears the menu with its own padding instead.
            .contentMargins(.leading, section == .settings ? 0 : SideMenu.collapsedWidth + 48, for: .scrollContent)
            // Start on the page, not in the menu, so the menu stays collapsed until you move into it.
            .prefersDefaultFocus(true, in: focusSpace)
            .environment(\.pageFocusSpace, focusSpace)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedBackground()

            SideMenu(selection: $section, onLeave: { resetFocus(in: focusSpace) }, onReselect: { pageResetID = UUID() })
        }
        .focusScope(focusSpace)
        // The menu hugs the left edge of the screen instead of sitting inside the TV's safe-area margin.
        .ignoresSafeArea(.container, edges: .leading)
        .onChange(of: section) { oldSection, _ in
            if oldSection == .settings { settingsResetID = UUID() }
        }
        // A Top Shelf link opens its title on Discover. Discover is rebuilt first, so nothing that was open on top
        // of it (an expanded section, a detail page, a sheet) can swallow the push, and the title is handed over
        // once the fresh page is in place.
        .onChange(of: app.incomingLink, initial: true) { _, link in
            guard let link else { return }
            app.incomingLink = nil
            section = .discover
            pageResetID = UUID()
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                app.deepLinkRoute = link
            }
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
