import Foundation
import CryptoKit

/// Keeps what Browse needs to show studio and network logos, so they appear straight away and still do when Seerr or
/// TMDB can't be reached: which logo each company has (asked of Seerr once, then remembered), and the logo images
/// themselves (saved in the app's cache folder after the first download).
enum LogoCache {
    private static let pathsKey = "browse.logoPaths"
    private static let lock = NSLock()

    private static func key(for target: BrowseTarget) -> String {
        "\(target.filter == .network ? "network" : "studio"):\(target.id)"
    }

    /// The logo path Seerr gave for this company earlier, if it did.
    static func path(for target: BrowseTarget) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: pathsKey) as? [String: String])?[key(for: target)]
    }

    static func save(_ path: String, for target: BrowseTarget) {
        lock.lock(); defer { lock.unlock() }
        var all = UserDefaults.standard.dictionary(forKey: pathsKey) as? [String: String] ?? [:]
        all[key(for: target)] = path
        UserDefaults.standard.set(all, forKey: pathsKey)
    }

    // MARK: - Images

    private static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BrowseLogos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func file(for url: URL) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name)
    }

    /// The image's bytes: from the cache folder if it's been downloaded before, otherwise downloaded now and kept.
    static func imageData(for url: URL) async -> Data? {
        let cached = file(for: url)
        if let data = try? Data(contentsOf: cached), !data.isEmpty { return data }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        try? data.write(to: cached, options: .atomic)
        return data
    }
}
