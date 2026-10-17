import SwiftUI

/// Shown for a watchlist service that isn't connected yet.
struct WatchlistConnectView: View {
    @Environment(AppState.self) private var app
    let store: WatchlistStore
    let source: WatchlistSource
    let onTraktSignIn: () -> Void

    @State private var input = ""
    @State private var error: String?
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Connect \(source.name)")
                .font(.title2).bold()

            switch source {
            case .trakt: trakt
            case .letterboxd: letterboxd
            }
        }
        .frame(maxWidth: 1300, alignment: .leading)
        .onChange(of: source) { _, _ in
            input = ""
            error = nil
        }
    }

    // MARK: - Trakt

    @ViewBuilder
    private var trakt: some View {
        if TraktConfig.isConfigured {
            Text("Sign in with a code. Your watchlist's movies and series appear here, and you choose what to request.")
                .foregroundStyle(.secondary)
            Button(action: onTraktSignIn) {
                Label("Sign In to Trakt", systemImage: "person.badge.key")
            }
            Text("Tip: Trakt can import your Letterboxd lists on its website. Do that once and they'll show up here too.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("This build doesn't have a Trakt app key yet. To add one:")
                Text("1. At developer.trakt.tv, create a new app named Oppresseerr. For the redirect URI use urn:ietf:wg:oauth:2.0:oob, or any https:// address you own.")
                Text("2. In project.yml, paste the Client ID into TRAKT_CLIENT_ID. If you used an https:// redirect, put the same address in TRAKT_REDIRECT_URI. New Trakt apps don't get a Client Secret, so leave that empty.")
                Text("3. Run xcodegen generate and build the app again.")
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Letterboxd

    @ViewBuilder
    private var letterboxd: some View {
        Text("Letterboxd doesn't let apps sign in, so Oppresseerr reads your public watchlist page. It never asks for your password.")
            .foregroundStyle(.secondary)

        TextField("Letterboxd username", text: $input)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(maxWidth: 900)
            .onSubmit(connect)

        Text("Your watchlist has to be public. Check your Letterboxd privacy settings if the import comes back empty.")
            .font(.callout)
            .foregroundStyle(.secondary)

        if let error {
            Text(error)
                .foregroundStyle(.red)
                .frame(maxWidth: 1200, alignment: .leading)
        }

        HStack(spacing: 24) {
            Button(action: connect) {
                Text("Import Watchlist").frame(minWidth: 280)
            }
            .disabled(input.trimmed.isEmpty || connecting)

            if connecting, case .working(let message) = store.phase[source] ?? .idle {
                ProgressView()
                Text(message).foregroundStyle(.secondary)
            }
        }
    }

    private func connect() {
        guard !connecting, !input.trimmed.isEmpty else { return }
        let target = source
        let text = input
        Task {
            connecting = true
            error = nil
            error = await store.connect(target, input: text, api: app.api)
            connecting = false
        }
    }
}

// MARK: - Trakt sign-in

struct TraktSignInView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let store: WatchlistStore

    @State private var code: TraktDeviceCode?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 60) {
            Text("Sign in to Trakt")
                .font(.largeTitle).bold()

            HStack(alignment: .center, spacing: 120) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("1. On your phone or computer, go to")
                        .foregroundStyle(.secondary)
                    Text(displayURL)
                        .font(.title2).bold()
                        .foregroundStyle(.tint)
                    Text("2. Enter this code")
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                    Text(code?.userCode ?? "········")
                        .font(.system(size: 96, weight: .heavy, design: .monospaced))
                        .kerning(12)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if code != nil, error == nil {
                        Label("Waiting for you to approve it on Trakt…", systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                QRCodeView(text: code?.verificationUrl ?? "https://auth.trakt.tv/activate")
                    .frame(width: 300, height: 300)
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1200)
            }

            HStack(spacing: 30) {
                Button("Get a New Code") { attempt += 1 }
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground()
        .task(id: attempt) { await runFlow() }
    }

    private var displayURL: String {
        (code?.verificationUrl ?? "https://auth.trakt.tv/activate")
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func runFlow() async {
        error = nil
        code = nil
        do {
            let newCode = try await store.trakt.requestDeviceCode()
            code = newCode
            var interval = max(newCode.interval, 1)
            let deadline = Date().addingTimeInterval(TimeInterval(newCode.expiresIn))

            while Date() < deadline {
                try await Task.sleep(for: .seconds(interval))
                switch await store.trakt.pollForToken(deviceCode: newCode.deviceCode) {
                case .signedIn:
                    let api = app.api
                    Task { await store.traktDidSignIn(api: api) }
                    dismiss()
                    return
                case .pending:
                    continue
                case .slowDown:
                    interval += 1
                case .expired:
                    error = "That code expired. Get a new one to try again."
                    return
                case .denied:
                    error = "The sign-in was declined on Trakt."
                    return
                case .failed(let message):
                    error = message
                    return
                }
            }
            error = "That code expired. Get a new one to try again."
        } catch is CancellationError {
            // Sheet closed or a new code was requested.
        } catch {
            self.error = AppState.friendly(error)
        }
    }
}
