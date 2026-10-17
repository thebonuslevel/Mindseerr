# Oppresseerr

Oppresseerr is a native SwiftUI Apple TV client for [Seerr](https://docs.seerr.dev) (the merged Overseerr + Jellyseerr project).

## Features

- **Plex sign-in** with the TV-friendly code flow: the app shows a 4-character code, you enter it at plex.tv/link on any device.
- **Jellyfin and Emby sign-in** with your media server username and password. The app asks Seerr which server it uses and shows the right screen.
- **Seerr account sign-in** (email and password, for accounts created in Seerr) and **API key sign-in** (signs in as the server's main admin account). Both are offered under "Or sign in with" on the sign-in screen.
- **Admin tab** for admins and users with the Manage Requests permission: request counts, filters (Pending, Processing, Failed, Available, All), Approve, Decline, Approve All, Retry for failed requests, and Delete.
- **Pure black (#000000) background** everywhere, so OLED pixels stay off behind the UI.
- **Discover**: Trending, Popular Movies, Upcoming Movies, Popular Series, Upcoming Series. Rows page in more titles as you scroll.
- **Search** across movies and series with the tvOS search keyboard.
- **Detail pages** with backdrop, overview, runtime/seasons, genres, rating and live availability.
- **Requests**: request a movie, or pick specific seasons of a series. Seasons already available or requested are locked.
- **My Requests**: everything you've requested with its approval and availability status.
- **Watchlists**: import your Trakt and Letterboxd watchlists, see which titles are already on your server, and request the rest one at a time or all at once.
- Session survives relaunches (cookie and sign-in credentials in the Keychain); if the Seerr session expires, the app silently signs in again.

## Requirements

- Mac with Xcode 16 or later
- tvOS 17+ (Apple TV HD or 4K, or the Apple TV simulator)
- A Seerr server using Plex, Jellyfin or Emby
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project: `brew install xcodegen`

## Build & run

```sh
cd Oppresseerr
xcodegen generate
open Oppresseerr.xcodeproj
```

1. Select the **Oppresseerr** target → *Signing & Capabilities* → pick your Team. Change the bundle ID from `com.example.oppresseerr` if you like (or edit `project.yml` and regenerate).
2. Choose an Apple TV simulator or your paired Apple TV and press **Run**.
3. Enter your server address (e.g. `http://192.168.1.10:5055` or `https://seerr.example.com`), then sign in with the Plex code.

To run on a real Apple TV: on the Apple TV open *Settings → Remotes and Devices → Remote App and Devices*, then in Xcode open *Window → Devices and Simulators* and pair it.

## Watchlists (Trakt, Letterboxd)

The **Watchlists** tab imports a watchlist, matches every title to your Seerr server and shows whether it's available, requested or missing. Open a title to request it, or use **Request All Missing**. Series are requested for every season that isn't already available or requested.

| Service | How it connects | What you need |
|---|---|---|
| Trakt | Real sign-in: a code on the TV, approved on Trakt's activation page | Your Trakt app's Client ID in `project.yml` (below) |
| Letterboxd | Reads your public watchlist page by username | Watchlist set to public |

Letterboxd's API is invite-only, so it doesn't allow an app sign-in. Oppresseerr reads the public watchlist page and never asks for your password. If Letterboxd changes its pages or blocks the request, import the watchlist into Trakt on trakt.tv and use the Trakt tab instead.

### Setting up Trakt

1. At [developer.trakt.tv](https://developer.trakt.tv/apps/new), create a new app named Oppresseerr. For the **Redirect URI**, use `urn:ietf:wg:oauth:2.0:oob`. Trakt warns about it because it's meant for web sign-ins, but Oppresseerr signs in with a code and never redirects. If Trakt won't save it, use any `https://` address you own instead. (Trakt may ask you to verify your account with GitHub first.)
2. In `project.yml`, paste the **Client ID** into `TRAKT_CLIENT_ID`. Leave `TRAKT_CLIENT_SECRET` empty: Trakt stopped issuing secrets to new apps in October 2026, and the TV code sign-in doesn't need one. If you registered an `https://` redirect, put the same address in `TRAKT_REDIRECT_URI`; it's sent when the app renews your sign-in and must match.
3. Run `xcodegen generate` and build again.

The Client ID is built into the app. That's expected for TV apps and isn't a secret on its own.

## Make an IPA

On your Mac, in Terminal:

```sh
cd Oppresseerr
./make-ipa.sh
```

It generates the project if needed, archives a Release build and writes `Oppresseerr.ipa` next to the script.

- **Signed (default)** uses the Team you picked in Xcode. It installs on Apple TVs registered to your team. Pair yours first (Xcode → Window → Devices and Simulators), then install the IPA from that same window: select the Apple TV, click **+** under *Installed Apps* and pick the file.
- **`TEAM=ABCDE12345 ./make-ipa.sh`** passes your team ID directly, if Xcode lost the Team setting after `xcodegen generate`.
- **`./make-ipa.sh --unsigned`** makes `Oppresseerr-unsigned.ipa` for signing later with another tool.

With a free Apple ID the signed app expires after 7 days; run the script again to renew it.

## Project layout

```
Oppresseerr/
├── make-ipa.sh                Builds Oppresseerr.ipa (see above)
├── project.yml                  XcodeGen spec (tvOS 17, ATS allows http for LAN servers)
└── Oppresseerr/
    ├── App/                     App entry, RootView, tabs, AppState (session & phase)
    ├── Models/                  Codable types for media, requests, users
    ├── Networking/              SeerrClient (actor), PlexAuth (PIN flow), Keychain
    │   └── Watchlists/          Trakt client, Letterboxd importer, WatchlistStore
    └── Views/
        ├── Onboarding/          Server address, sign-in (Plex, Jellyfin/Emby, Seerr account, API key)
        ├── Admin/               Approve, decline, retry and delete requests
        ├── Discover/            Paginated poster rows
        ├── Search/              Debounced search grid
        ├── Detail/              Detail page + season picker
        ├── Requests/            My Requests list
        ├── Watchlists/          Watchlists tab, connect screens, Trakt sign-in
        ├── Settings/            Account, server, sign out
        └── Components/          Posters and status badges
```

## How it talks to Seerr

All calls go to `<server>/api/v1`:

| Purpose | Endpoint |
|---|---|
| Validate server | `GET /status` |
| Server type | `GET /settings/public` (`mediaServerType`: 1 Plex, 2 Jellyfin, 3 Emby) |
| Sign in | `POST /auth/plex` `{ authToken }`, `POST /auth/jellyfin` `{ username, password }` or `POST /auth/local` `{ email, password }` → `connect.sid` cookie; or an `X-Api-Key` header on every request |
| Current user | `GET /auth/me` |
| Discover rows | `GET /discover/trending`, `/discover/movies`, `/discover/movies/upcoming`, `/discover/tv`, `/discover/tv/upcoming` |
| Search | `GET /search?query=…&page=…` |
| Details | `GET /movie/{tmdbId}`, `GET /tv/{tmdbId}` |
| Request | `POST /request` `{ mediaType, mediaId, seasons?, is4k }` |
| My requests | `GET /request?requestedBy={userId}&take=&skip=&sort=added` |
| Match an IMDb ID | `GET /search?query=imdb:tt…` |
| Admin: list / counts | `GET /request?filter=pending\|processing\|failed\|available\|all`, `GET /request/count` |
| Admin: actions | `POST /request/{id}/approve`, `POST /request/{id}/decline`, `POST /request/{id}/retry`, `DELETE /request/{id}` |

## Notes & troubleshooting

- **API key sign-in** acts as Seerr's main admin account (user 1), so requests you make are made as that account. Use it only on your own Apple TV. The key is in Seerr → Settings → General.
- **Seerr account sign-in** needs *Settings → Users → Enable Local Sign-In* turned on in Seerr. Seerr accounts sign in by email, not username.

- **"Access denied" after signing in**: the account has to be allowed on the Seerr server. In Seerr, import the user (*Users → Import Plex/Jellyfin Users*) or enable new Plex/Jellyfin sign-ins under *Settings → Users*.
- **Jellyfin password storage**: to sign back in silently when the Seerr session expires, the Jellyfin username and password are kept in the Apple TV Keychain. Signing out deletes them.
- **CSRF protection**: if *Settings → Network → CSRF Protection* is turned on in Seerr, POST requests from the app will be rejected. Leave it off (the default) or extend `SeerrClient` to send the XSRF token.
- **Self-signed HTTPS** certificates aren't trusted by tvOS. Use plain `http://` on your LAN or a real certificate (e.g. via a reverse proxy).
- **App icon**: `Assets.xcassets` holds a layered tvOS icon (Front / Middle / Back layers for the parallax tilt) and Top Shelf images. To use your own artwork, open the asset catalog in Xcode and drag PNGs onto each slot: icon layers at 400×240 (@1x) and 800×480 (@2x), the App Store icon at 1280×768, Top Shelf at 1920×720 / 3840×1440, and Top Shelf Wide at 2320×720 / 4640×1440. The Back layer must have no transparency.

## Ideas for next steps

- 4K requests (`is4k: true`) when the server has a 4K Radarr/Sonarr
- Request-option overrides (server, quality profile, root folder) for users with *Advanced Requests*
- Cast & crew and "Similar"/"Recommended" rows on detail pages
- Top Shelf extension showing trending titles
