import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Launch

struct LaunchView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 40) {
            if let error = app.launchError {
                ContentUnavailableView("Can't Reach Your Server",
                                       systemImage: "wifi.exclamationmark",
                                       description: Text(error))
                HStack(spacing: 30) {
                    Button("Retry") { Task { await app.bootstrap() } }
                    Button("Change Server") { Task { await app.changeServer() } }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Server address

struct ServerSetupView: View {
    @Environment(AppState.self) private var app
    @State private var address = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 40) {
            Image("CthulhuMark")
                .resizable()
                .scaledToFit()
                .frame(height: 220)
                .accessibilityHidden(true)
            Text("Connect to Seerr")
                .font(.largeTitle).bold()
            Text("Enter your Seerr server's address, including the port if it has one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("http://192.168.1.10:5055 or https://seerr.example.com", text: $address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: 1000)
                .onSubmit(connect)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1000)
            }

            Button(action: connect) {
                if connecting { ProgressView() } else { Text("Connect").frame(minWidth: 240) }
            }
            .disabled(address.trimmed.isEmpty || connecting)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if address.isEmpty, let saved = app.serverURL?.absoluteString { address = saved }
        }
    }

    private func connect() {
        guard !connecting else { return }
        Task {
            connecting = true
            error = nil
            do {
                try await app.connect(to: address)
            } catch {
                self.error = AppState.friendly(error)
            }
            connecting = false
        }
    }
}

// MARK: - Sign-in chooser

enum SignInMethod: String, CaseIterable, Identifiable {
    case plex, jellyfin, local, apiKey

    var id: String { rawValue }

    func title(for kind: MediaServerKind) -> String {
        switch self {
        case .plex: return "Plex"
        case .jellyfin: return kind == .emby ? "Emby" : "Jellyfin"
        case .local: return "Seerr Account"
        case .apiKey: return "API Key"
        }
    }
}

/// Starts on the sign-in that matches the server (Plex, or Jellyfin/Emby) and offers the others below:
/// a Seerr account (email and password) or the server's API key.
struct SignInView: View {
    @Environment(AppState.self) private var app
    @State private var chosen: SignInMethod?

    private var methods: [SignInMethod] {
        switch app.serverKind {
        case .plex: return [.plex, .local, .apiKey]
        case .jellyfin, .emby: return [.jellyfin, .local, .apiKey]
        case .unknown: return [.plex, .jellyfin, .local, .apiKey]
        }
    }

    var body: some View {
        let available = methods
        let method = chosen.flatMap { available.contains($0) ? $0 : nil } ?? available[0]

        VStack(spacing: 50) {
            Group {
                switch method {
                case .plex:
                    PlexSignInView()
                case .jellyfin:
                    PasswordSignInView(kind: .jellyfin(serverName: method.title(for: app.serverKind)))
                case .local:
                    PasswordSignInView(kind: .local)
                case .apiKey:
                    APIKeySignInView()
                }
            }
            .id(method)

            HStack(spacing: 30) {
                Text("Or sign in with")
                    .foregroundStyle(.secondary)
                ForEach(available.filter { $0 != method }) { other in
                    Button(other.title(for: app.serverKind)) { chosen = other }
                }
                Button("Change Server") { Task { await app.changeServer() } }
            }
            .focusSection()
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await app.refreshServerKind() }
    }
}

// MARK: - Username / email + password

/// Jellyfin or Emby (username) and Seerr accounts (email) both sign in with a password.
struct PasswordSignInView: View {
    enum Kind {
        case jellyfin(serverName: String)
        case local
    }

    @Environment(AppState.self) private var app
    let kind: Kind

    @State private var name = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case name, password }

    private var isLocal: Bool {
        if case .local = kind { return true }
        return false
    }

    private var title: String {
        switch kind {
        case .jellyfin(let server): return "Sign in with \(server)"
        case .local: return "Sign in with a Seerr Account"
        }
    }

    private var subtitle: String {
        switch kind {
        case .jellyfin(let server):
            return "Use the same username and password you use for \(server)."
        case .local:
            return "Use the email address and password of your Seerr account. Seerr accounts sign in by email, and the server has to allow password sign-in."
        }
    }

    private var canSubmit: Bool {
        // Jellyfin allows empty passwords; Seerr accounts don't.
        !name.trimmed.isEmpty && (!isLocal || !password.isEmpty) && !signingIn
    }

    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: isLocal ? "person.crop.circle.badge.checkmark" : "person.crop.circle.fill")
                .font(.system(size: 110))
                .foregroundStyle(.tint)
            Text(title)
                .font(.largeTitle).bold()
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1200)

            VStack(spacing: 24) {
                TextField(isLocal ? "Email" : "Username", text: $name)
                    .textContentType(isLocal ? .emailAddress : .username)
                    .keyboardType(isLocal ? .emailAddress : .default)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit(signIn)
            }
            .frame(maxWidth: 800)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1000)
            }

            Button(action: signIn) {
                if signingIn { ProgressView() } else { Text("Sign In").frame(minWidth: 240) }
            }
            .disabled(!canSubmit)
        }
    }

    private func signIn() {
        guard canSubmit else { return }
        let credentials: Credentials = isLocal
            ? .local(email: name.trimmed.lowercased(), password: password)
            : .jellyfin(username: name.trimmed, password: password)
        Task {
            signingIn = true
            error = nil
            do {
                try await app.signIn(with: credentials)
            } catch {
                self.error = AppState.friendly(error)
            }
            signingIn = false
        }
    }
}

// MARK: - API key

struct APIKeySignInView: View {
    @Environment(AppState.self) private var app
    @State private var key = ""
    @State private var signingIn = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: "key.fill")
                .font(.system(size: 110))
                .foregroundStyle(.tint)
            Text("Sign in with an API Key")
                .font(.largeTitle).bold()
            Text("Find the key in Seerr under Settings → General. It signs you in as the server's main admin account, so only use it on your own Apple TV.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1200)

            SecureField("API key", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: 1000)
                .onSubmit(signIn)

            Text("Tip: when the keyboard is open, your iPhone shows a notification so you can paste the key there.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1000)
            }

            Button(action: signIn) {
                if signingIn { ProgressView() } else { Text("Sign In").frame(minWidth: 240) }
            }
            .disabled(key.trimmed.isEmpty || signingIn)
        }
    }

    private func signIn() {
        let value = key.trimmed
        guard !value.isEmpty, !signingIn else { return }
        Task {
            signingIn = true
            error = nil
            do {
                try await app.signIn(with: .apiKey(value))
            } catch {
                self.error = AppState.friendly(error)
            }
            signingIn = false
        }
    }
}

// MARK: - Plex sign-in

struct PlexSignInView: View {
    @Environment(AppState.self) private var app
    @State private var pin: PlexPin?
    @State private var error: String?
    @State private var signingIn = false
    @State private var attempt = 0
    @State private var confirmed = false

    /// What the task restarts on: a new code was asked for, or the server was confirmed.
    private struct FlowKey: Hashable { let attempt: Int; let confirmed: Bool }

    var body: some View {
        if confirmed || PlexHostTrust.isTrusted(app.serverURL) {
            link.onAppear { confirmed = true }
        } else {
            hostConfirmation
        }
    }

    /// Plex sign-in sends a token to the Seerr server, so the first time for each address the user sees which
    /// one, and that an unencrypted one would send it unprotected.
    private var hostConfirmation: some View {
        VStack(spacing: 40) {
            Text("Sign in with Plex")
                .font(.largeTitle).bold()
            Text("Your Plex sign-in will be sent to")
                .foregroundStyle(.secondary)
            Text(PlexHostTrust.label(for: app.serverURL))
                .font(.title2).bold()
            if PlexHostTrust.isUnencryptedRemote(app.serverURL) {
                Text("This address isn't encrypted, and isn't on your home network. Anyone between your Apple TV and the server could read the sign-in. Use an https:// address if you can.")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            }
            Button("Continue") {
                PlexHostTrust.trust(app.serverURL)
                confirmed = true
            }
        }
        .padding(80)
    }

    private var link: some View {
        VStack(spacing: 60) {
            Text("Sign in with Plex")
                .font(.largeTitle).bold()

            HStack(alignment: .center, spacing: 120) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("1. On your phone or computer, go to")
                        .foregroundStyle(.secondary)
                    Text("plex.tv/link")
                        .font(.title2).bold()
                        .foregroundStyle(.tint)
                    Text("2. Enter this code")
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                    Text(pin?.code ?? "····")
                        .font(.system(size: 120, weight: .heavy, design: .monospaced))
                        .kerning(18)
                        .contentTransition(.numericText())

                    Group {
                        if signingIn {
                            Label("Signing in to Seerr…", systemImage: "checkmark.circle")
                        } else if pin != nil {
                            Label("Waiting for you to enter the code…", systemImage: "hourglass")
                        } else if error == nil {
                            Label("Getting a code…", systemImage: "hourglass")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                QRCodeView(text: "https://plex.tv/link")
                    .frame(width: 300, height: 300)
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1200)
            }

            Button("Get a New Code") { attempt += 1 }
                .disabled(signingIn)
        }
        .task(id: FlowKey(attempt: attempt, confirmed: confirmed)) { await runFlow() }
    }

    private func runFlow() async {
        guard confirmed else { return }
        error = nil
        pin = nil
        do {
            let newPin = try await PlexAuth.createPin()
            pin = newPin
            let deadline = Date().addingTimeInterval(TimeInterval(newPin.expiresIn ?? 900))

            while Date() < deadline {
                try await Task.sleep(for: .seconds(2))
                // Ignore transient polling failures; keep waiting until the code expires.
                guard let checked = try? await PlexAuth.checkPin(newPin.id),
                      let token = checked.authToken, !token.isEmpty else { continue }

                signingIn = true
                defer { signingIn = false }
                try await app.signIn(with: .plex(token: token))
                return
            }
            error = "That code expired. Get a new one to try again."
        } catch is CancellationError {
            // View went away or a new code was requested.
        } catch {
            pin = nil
            self.error = AppState.friendly(error)
        }
    }
}

/// Which Seerr addresses the user has agreed to send a Plex sign-in to.
enum PlexHostTrust {
    private static let key = "trustedPlexHosts"

    static func label(for url: URL?) -> String {
        guard let url, let host = url.host else { return "this server" }
        return (url.scheme ?? "http") + "://" + host + (url.port.map { ":\($0)" } ?? "")
    }

    static func isTrusted(_ url: URL?) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(label(for: url))
    }

    static func trust(_ url: URL?) {
        var all = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !all.contains(label(for: url)) { all.append(label(for: url)) }
        UserDefaults.standard.set(all, forKey: key)
    }

    /// An http:// address that isn't a home-network one (a private IP address, localhost or a .local name).
    static func isUnencryptedRemote(_ url: URL?) -> Bool {
        guard let url, url.scheme == "http", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home") { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            return !(parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
                     || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254))
        }
        return host.contains(".")   // a bare name (no dots) is a home-network one
    }
}

struct QRCodeView: View {
    private let image: CGImage?

    init(text: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        if let output = filter.outputImage {
            image = CIContext().createCGImage(output, from: output.extent)
        } else {
            image = nil
        }
    }

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(20)
                .background(.white, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}
