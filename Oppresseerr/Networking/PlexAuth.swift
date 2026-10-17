import Foundation

struct PlexPin: Decodable, Sendable {
    let id: Int
    let code: String
    let authToken: String?
    let expiresIn: Int?
}

/// Plex's device-link flow: create a short PIN, the user enters it at plex.tv/link,
/// and polling the PIN eventually returns an auth token.
enum PlexAuth {
    static let product = "Oppresseerr"

    static var clientIdentifier: String {
        let key = "plexClientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// `strong=false` returns a 4-character code that plex.tv/link accepts.
    static func createPin() async throws -> PlexPin {
        var request = makeRequest(URL(string: "https://plex.tv/api/v2/pins?strong=false")!)
        request.httpMethod = "POST"
        return try await fetch(request)
    }

    static func checkPin(_ id: Int) async throws -> PlexPin {
        try await fetch(makeRequest(URL(string: "https://plex.tv/api/v2/pins/\(id)")!))
    }

    private static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                         forHTTPHeaderField: "X-Plex-Version")
        request.setValue("tvOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("Apple TV", forHTTPHeaderField: "X-Plex-Device")
        return request
    }

    private static func fetch(_ request: URLRequest) async throws -> PlexPin {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                           message: "Couldn't reach Plex. Try again in a moment.")
        }
        return try JSONDecoder().decode(PlexPin.self, from: data)
    }
}
