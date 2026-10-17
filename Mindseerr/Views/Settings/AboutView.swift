import SwiftUI

/// Opened by selecting the logo on the Settings page: version, project link and data-source credits.
struct AboutView: View {
    private static let githubURL = "https://github.com/thebonuslevel/Mindseerr"

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 20) {
                    Image("CthulhuMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 240)
                        .accessibilityHidden(true)
                    Text("Mindseerr")
                        .font(.largeTitle).bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .focusable(false)
            }

            Section {
                LabeledContent("Version", value: version)
                HStack(spacing: 40) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GitHub")
                        Text(Self.githubURL.replacingOccurrences(of: "https://", with: ""))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    QRCodeView(text: Self.githubURL)
                        .frame(width: 160, height: 160)
                }
            }

            Section("Credits") {
                credit("Trakt.tv", "Watchlist data is provided by Trakt.tv. Mindseerr is not affiliated with or endorsed by Trakt.")
                credit("TMDB", "This product uses the TMDB API but is not endorsed or certified by TMDB. Posters and titles come from The Movie Database.")
                credit("TheTVDB", "Metadata is provided by TheTVDB.com. Please consider adding missing information or subscribing to support them.")
                credit("Plex", "Plex is a trademark of Plex, Inc. Mindseerr is not affiliated with or endorsed by Plex.")
            }
        }
        .themedBackground()
        .navigationTitle("About")
    }

    private func credit(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        // Read-only rows still need to be reachable so the list can scroll with the remote.
        .focusable()
    }
}
