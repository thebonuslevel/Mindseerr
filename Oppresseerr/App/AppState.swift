import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum Phase { case launching, serverSetup, signIn, ready }

    var phase: Phase = .launching
    /// A theme shown temporarily while it's highlighted in Appearance; nil shows the saved theme.
    var previewTheme: AppTheme?
    /// Sonarr/Radarr download progress, shown on posters, detail pages and the Admin tab.
    let downloads = DownloadMonitor()
    private(set) var launchError: String?
    private(set) var serverURL: URL?
    private(set) var serverKind: MediaServerKind = .unknown
    private(set) var client: SeerrClient?
    private(set) var user: SeerrUser?
    private(set) var serverVersion: String?
    private(set) var signInMethod: String?

    /// Only valid once signed in (phase == .ready).
    var api: SeerrClient {
        guard let client else { preconditionFailure("API used before a server was configured") }
        return client
    }

    private enum Keys {
        static let server = "serverURL"
        static let cookie = "seerrSession"
    }

    init() {
        #if DEBUG
        // Demo mode for README screenshots: talk to a local stand-in server (see `DemoMode`) and touch
        // nothing that's saved, so the real sign-in and server stay exactly as they were.
        if let url = DemoMode.seerrURL {
            serverURL = url
            client = SeerrClient(baseURL: url, sessionCookie: nil, credentials: .apiKey("demo"))
            signInMethod = "API key (demo)"
            return
        }
        #endif
        if let saved = UserDefaults.standard.string(forKey: Keys.server), let url = URL(string: saved) {
            serverURL = url
            client = Self.makeClient(url)
        }
        signInMethod = Credentials.load()?.methodName
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        launchError = nil
        guard let client else { phase = .serverSetup; return }
        do {
            user = try await client.currentUser()
            phase = .ready
            serverVersion = try? await client.status().version
        } catch let error as URLError {
            launchError = Self.friendly(error)
            phase = .launching
        } catch {
            phase = .signIn
        }
    }

    func connect(to input: String) async throws {
        #if DEBUG
        if DemoMode.seerrURL != nil { return } // never touch the real saved server or sign-in in demo mode
        #endif
        guard let url = Self.normalize(input) else {
            throw APIError(status: 0, message: "That doesn't look like a valid address.")
        }
        let probe = SeerrClient(baseURL: url, sessionCookie: nil, credentials: nil)
        let status: ServerStatus
        do {
            status = try await probe.status()
        } catch let error as APIError {
            throw APIError(status: error.status,
                           message: "That address responded, but it doesn't look like a Seerr server.")
        }
        serverVersion = status.version
        serverKind = MediaServerKind(code: (try? await probe.publicSettings())?.mediaServerType)
        serverURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: Keys.server)
        Keychain.set(nil, for: Keys.cookie)
        client = Self.makeClient(url)
        phase = .signIn
    }

    /// Asks the server whether it's set up for Plex, Jellyfin or Emby, so sign-in can show the right screen.
    func refreshServerKind() async {
        guard serverKind == .unknown, let client else { return }
        serverKind = MediaServerKind(code: (try? await client.publicSettings())?.mediaServerType)
    }

    func signIn(with credentials: Credentials) async throws {
        #if DEBUG
        if DemoMode.seerrURL != nil { return } // never touch the real saved server or sign-in in demo mode
        #endif
        guard let serverURL else { phase = .serverSetup; return }
        let probe = SeerrClient(baseURL: serverURL, sessionCookie: nil, credentials: nil,
                                onSessionChange: { cookie in Keychain.set(cookie, for: Keys.cookie) })
        do {
            user = try await probe.login(with: credentials)
        } catch let error as APIError {
            throw Self.signInError(error, for: credentials)
        }
        Credentials.save(credentials)
        signInMethod = credentials.methodName
        client = Self.makeClient(serverURL)
        phase = .ready
    }

    func signOut() async {
        #if DEBUG
        if DemoMode.seerrURL != nil { return } // never touch the real saved server or sign-in in demo mode
        #endif
        await client?.logout()
        Keychain.set(nil, for: Keys.cookie)
        Credentials.save(nil)
        signInMethod = nil
        user = nil
        if let serverURL { client = Self.makeClient(serverURL) }
        phase = .signIn
    }

    func changeServer() async {
        #if DEBUG
        if DemoMode.seerrURL != nil { return } // never touch the real saved server or sign-in in demo mode
        #endif
        await signOut()
        UserDefaults.standard.removeObject(forKey: Keys.server)
        serverURL = nil
        serverKind = .unknown
        serverVersion = nil
        client = nil
        launchError = nil
        phase = .serverSetup
    }

    func refreshServerVersion() async {
        if let version = try? await client?.status().version { serverVersion = version }
    }

    // MARK: - Helpers

    private static func makeClient(_ url: URL) -> SeerrClient {
        SeerrClient(
            baseURL: url,
            sessionCookie: Keychain.get(Keys.cookie),
            credentials: Credentials.load(),
            onSessionChange: { cookie in Keychain.set(cookie, for: Keys.cookie) }
        )
    }

    private static func signInError(_ error: APIError, for credentials: Credentials) -> APIError {
        switch (credentials, error.status) {
        case (.jellyfin, 401):
            return APIError(status: 401, message: "Wrong username or password.")
        case (.jellyfin, 403):
            return APIError(status: 403, message:
                "This account doesn't have access to this Seerr server. Ask the owner to import your account or allow new Jellyfin sign-ins.")
        case (.local, 401), (.local, 403):
            return APIError(status: error.status, message: "That email and password didn't work for this Seerr server.")
        case (.apiKey, 401), (.apiKey, 403):
            return APIError(status: error.status, message:
                "That API key isn't valid for this server. Copy it again from Seerr → Settings → General.")
        case (.plex, 401), (.plex, 403):
            return APIError(status: error.status, message:
                "This Plex account doesn't have access to this Seerr server. Ask the owner to import your account or allow new Plex sign-ins.")
        default:
            return error
        }
    }

    static func normalize(_ input: String) -> URL? {
        var text = input.trimmed
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    static func friendly(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach that server. Check the address and that your Apple TV is on the same network."
            case .timedOut:
                return "The server took too long to respond."
            case .notConnectedToInternet, .networkConnectionLost:
                return "Your Apple TV isn't connected to the network."
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                return "The server's HTTPS certificate isn't trusted by Apple TV."
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
