import Foundation

/// What a torrent's release name says about the title: "The.Drowned.Lighthouse.2026.1080p.WEB-DL" is
/// the title "The Drowned Lighthouse" from 2026, and "Deep.Station.S02E05.720p" is season 2, episode 5 of "Deep Station".
/// Used to match torrents to Seerr titles when there's no Sonarr or Radarr to say which title a download is for.
struct ReleaseName: Equatable, Sendable {
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?

    var isSeries: Bool { season != nil }

    /// "Season 2, Episode 5" or "Season 2", for series. Nil for movies.
    var episodeLabel: String? {
        guard let season else { return nil }
        if let episode { return "Season \(season), Episode \(episode)" }
        return "Season \(season)"
    }

    static func parse(_ raw: String) -> ReleaseName {
        var text = raw
        // Drop a trailing file extension and any leading [Group] tag.
        if let dot = text.lastIndex(of: "."), text[text.index(after: dot)...].count <= 4,
           ["mkv", "mp4", "avi", "m4v", "mov", "ts"].contains(text[text.index(after: dot)...].lowercased()) {
            text = String(text[..<dot])
        }
        text = text.replacingOccurrences(of: #"^\s*\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")

        var cut = text.endIndex
        var season: Int?
        var episode: Int?
        var year: Int?

        func firstMatch(_ pattern: String) -> NSTextCheckingResult? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        }
        func shorten(to match: NSTextCheckingResult) {
            if let range = Range(match.range, in: text), range.lowerBound < cut { cut = range.lowerBound }
        }
        func number(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            Range(match.range(at: group), in: text).flatMap { Int(text[$0]) }
        }

        // Season / episode markers: S02E05, S02, Season 2, 2x05.
        if let m = firstMatch(#"\bS(\d{1,2})[ -]?E(\d{1,3})\b"#) {
            season = number(m, 1); episode = number(m, 2); shorten(to: m)
        } else if let m = firstMatch(#"\bS(\d{1,2})\b"#) ?? firstMatch(#"\bSeasons? ?(\d{1,2})\b"#) {
            season = number(m, 1); shorten(to: m)
        } else if let m = firstMatch(#"\b(\d{1,2})x(\d{2})\b"#) {
            season = number(m, 1); episode = number(m, 2); shorten(to: m)
        }

        // A year after the title starts (a title can itself be a year, like "1917").
        if let regex = try? NSRegularExpression(pattern: #"\b((?:19|20)\d{2})\b"#) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if let m = matches.first(where: { Range($0.range, in: text).map { $0.lowerBound > text.startIndex } ?? false }) {
                year = number(m, 1)
                shorten(to: m)
            }
        }

        // Quality and source tags end the title too.
        if let m = firstMatch(#"\b(480p|576p|720p|1080p|2160p|4k|uhd|web-?dl|web-?rip|blu-?ray|brrip|bdrip|hdtv|dvdrip|x26[45]|h ?26[45]|hevc|remux|complete|proper|repack)\b"#) {
            shorten(to: m)
        }

        let title = String(text[..<cut])
            .replacingOccurrences(of: #"[\s\-–(\[]+$"#, with: "", options: .regularExpression)
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return ReleaseName(title: title.isEmpty ? raw : title, year: year, season: season, episode: episode)
    }
}
