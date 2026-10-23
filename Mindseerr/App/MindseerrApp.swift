import SwiftUI

@main
struct MindseerrApp: App {
    @State private var app = AppState()

    init() {
        FocusRedirect.install()
        #if DEBUG
        // Logs every move of the focus (what it left, what it landed on, which way it was heading), to find out why a
        // remote press goes where it does.
        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            func describe(_ item: UIFocusItem?) -> String {
                guard let item else { return "nil" }
                let frame = item.frame
                let view = item as? UIView
                let label = view?.accessibilityLabel ?? (view.map { String(describing: type(of: $0)) } ?? String(describing: type(of: item)))
                return "\(label) [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))]"
            }
            FocusLog.write("FOCUS \(describe(context.previouslyFocusedItem)) -> \(describe(context.nextFocusedItem)) heading=\(context.focusHeading.rawValue)")
        }
        #endif
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
            #if DEBUG
            // mindseerr://debug-redirect acts out the keyboard-down-to-menu fix, for trying it without a real Apple TV.
            if url.host == "debug-redirect" { NotificationCenter.default.post(name: .redirectToSearchResults, object: nil); return }
            #endif
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
    #if DEBUG
    /// MINDSEERR_START_SECTION=search (and so on) opens on that section, for screenshots without driving the remote.
    @State private var section = AppSection.allCases.first { String(describing: $0) == ProcessInfo.processInfo.environment["MINDSEERR_START_SECTION"] } ?? .discover
    #else
    @State private var section = AppSection.discover
    #endif
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
                case .browse: BrowseView()
                case .search: SearchView()
                case .watchlists: WatchlistsView()
                case .activity: ActivityView()
                case .settings: SettingsView().id(settingsResetID)
                }
            }
            .id(pageResetID)
            // Settings is a List, which only applies this margin some of the time (its rows jump left and its section
            // headers appear and vanish as it scrolls), so it clears the menu with its own padding instead.
            .contentMargins(.leading, section == .settings ? 0 : SideMenu.collapsedWidth + 48 - (section == .search ? SearchView.menuClearance : 0), for: .scrollContent)
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
        .task(id: app.downloads.services) { await app.resolutions.refreshMovies(services: app.downloads.services) }
    }
}

extension View {
    /// Every tab's NavigationStack can open a movie or series.
    func mediaDestinations() -> some View {
        navigationDestination(for: MediaRoute.self) { route in
            MediaDetailView(route: route)
                .themedBackground()
        }
        .navigationDestination(for: BrowseTarget.self) { target in
            BrowseResultsView(target: target)
                .themedBackground()
        }
        .navigationDestination(for: PersonRoute.self) { person in
            PersonView(person: person)
                .themedBackground()
        }
    }
}

extension Notification.Name {
    /// Asks the Search page to put the cursor on its results (or on its resting spot when there are none).
    static let redirectToSearchResults = Notification.Name("redirectToSearchResults")
}

/// On a real Apple TV the search keyboard is one wide focus target, and the closest thing below it is the first icon of
/// the side menu, not the results. So pressing down from the keyboard lands in the menu. This watches for that exact
/// move and sends the cursor to the results instead.
enum FocusRedirect {
    /// Set when the cursor was just sent away from the menu, so the menu doesn't also send it back to the page's start.
    @MainActor static var suppressMenuLeave = false

    @MainActor static func install() {
        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
                  context.focusHeading == .down,
                  let previous = context.previouslyFocusedItem,
                  String(describing: type(of: previous)).contains("Keyboard"),
                  let next = context.nextFocusedItem,
                  // The menu's rows are small and start at the screen's left edge; nothing on a page is both.
                  next.frame.minX < 100, next.frame.width < 500, next.frame.height < 120 else { return }
            MainActor.assumeIsolated {
                suppressMenuLeave = true
                // Keep the menu looking closed for the instant it holds the cursor, so it doesn't flash open.
                MenuHold.shared.held = true
                Task { try? await Task.sleep(for: .milliseconds(600)); MenuHold.shared.held = false }
            }
            NotificationCenter.default.post(name: .redirectToSearchResults, object: nil)
            FocusLog.write("REDIRECT keyboard-down-to-menu -> search results")
        }
    }
}

/// A debug-only log of where the focus goes, kept in a file that can be copied off an Apple TV.
enum FocusLog {
    static func write(_ text: String) {
        #if DEBUG
        let line = "\(Date().formatted(.iso8601)) \(text)\n"
        NSLog("%@", line)
        if let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("focus.log"),
           let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
            else { try? data.write(to: url) }
        }
        #endif
    }
}

/// True for the instant the cursor is passing through the menu on its way to Search's results (see FocusRedirect), so the
/// menu stays collapsed and unhighlighted instead of flashing open.
@MainActor
@Observable
final class MenuHold {
    static let shared = MenuHold()
    var held = false
}
