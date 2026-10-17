import Foundation

/// Talks to a qBittorrent server through its Web API (v4.1+). Mindseerr uses it to pause and resume the
/// torrents that Sonarr and Radarr are downloading, matched by the torrent's info hash.
///
/// One client per server: each keeps its own session, since qBittorrent signs in with a cookie.
actor QBittorrentClient {
    private let service: ArrService
    private let session: URLSession
    private var signedIn = false

    init(service: ArrService) {
        self.service = service
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    // MARK: - Reading

    /// Checks the address and sign-in. Returns the server's version, or throws a readable error.
    func checkConnection() async throws -> String {
        try await login()
        let data = try await call("app/version", method: "GET")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The info hashes (lowercased) of every torrent on the server.
    func torrentHashes() async throws -> Set<String> {
        struct Torrent: Decodable { let hash: String }
        let data = try await call("torrents/info", method: "GET")
        guard let torrents = try? JSONDecoder().decode([Torrent].self, from: data) else {
            throw APIError(status: 0, message: "\(service.name) sent a response the app didn't understand. Is that a qBittorrent server?")
        }
        return Set(torrents.map { $0.hash.lowercased() })
    }

    // MARK: - Controlling

    func pause(hash: String) async throws {
        // qBittorrent 5 renamed pause/resume to stop/start.
        try await control(hash: hash, "torrents/pause", fallback: "torrents/stop")
    }

    func resume(hash: String) async throws {
        try await control(hash: hash, "torrents/resume", fallback: "torrents/start")
    }

    private func control(hash: String, _ path: String, fallback: String) async throws {
        do {
            _ = try await call(path, method: "POST", form: ["hashes": hash])
        } catch let error as APIError where error.status == 404 {
            _ = try await call(fallback, method: "POST", form: ["hashes": hash])
        }
    }

    // MARK: - Plumbing

    private func login() async throws {
        let (data, status) = try await raw("auth/login", method: "POST", form: [
            "username": service.username ?? "",
            "password": service.password ?? "",
        ])
        guard status == 200 else {
            throw failure(status: status)
        }
        guard String(decoding: data, as: UTF8.self).contains("Ok") else {
            throw APIError(status: 401, message: "\(service.name) rejected the username or password.")
        }
        signedIn = true
    }

    /// A request that signs in first if needed and once more if the session has expired.
    private func call(_ path: String, method: String, form: [String: String]? = nil) async throws -> Data {
        if !signedIn { try await login() }
        var (data, status) = try await raw(path, method: method, form: form)
        if status == 403 {
            try await login()
            (data, status) = try await raw(path, method: method, form: form)
        }
        guard (200..<300).contains(status) else { throw failure(status: status) }
        return data
    }

    private func raw(_ path: String, method: String, form: [String: String]? = nil) async throws -> (Data, Int) {
        let url = service.baseURL.appendingPathComponent("api/v2").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        // qBittorrent's CSRF protection wants the request to say which page it came from.
        request.setValue(service.baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(service.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.encode(form).utf8)
        }
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code != .cancelled {
            throw APIError(status: 0, message: "Couldn't reach \(service.name) at \(service.baseURL.absoluteString). Check the address and port.")
        }
    }

    private func failure(status: Int) -> APIError {
        switch status {
        case 401, 403:
            return APIError(status: status, message: "\(service.name) refused the sign-in. Check the username and password, and that the Web UI is enabled in qBittorrent.")
        case 404:
            return APIError(status: status, message: "\(service.name) didn't recognize that address. Use the Web UI address, like http://192.168.1.10:8080.")
        default:
            return APIError(status: status, message: "\(service.name) returned error \(status).")
        }
    }

    private static func encode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return form
            .map { key, value in
                "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .sorted()
            .joined(separator: "&")
    }
}
