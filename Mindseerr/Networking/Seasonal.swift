import Foundation

/// A holiday that has a row of seasonal picks on Discover while it's coming up.
struct Holiday: Identifiable, Sendable {
    let id: String
    let emoji: String
    /// What TMDB's keyword search is asked for to find its titles.
    let keyword: String
    /// How many days before the day the row appears.
    let leadDays: Int
    /// How many days after the day it stays.
    var trailDays = 2
    /// A whole month or season rather than a day: only featured when no particular holiday is near.
    var broad = false

    var name: String {
        switch id {
        case "newYear": return String(localized: "New Year's Eve")
        case "valentines": return String(localized: "Valentine's Day")
        case "stPatricks": return String(localized: "St. Patrick's Day")
        case "easter": return String(localized: "Easter")
        case "july4": return String(localized: "Fourth of July")
        case "halloween": return String(localized: "Halloween")
        case "thanksgiving": return String(localized: "Thanksgiving")
        case "memorial": return String(localized: "Memorial Day")
        case "mothers": return String(localized: "Mother's Day")
        case "fathers": return String(localized: "Father's Day")
        case "juneteenth": return String(localized: "Juneteenth")
        case "pride": return String(localized: "Pride")
        case "summer": return String(localized: "Summer")
        case "labor": return String(localized: "Labor Day")
        default: return String(localized: "Christmas")
        }
    }

    /// The row's title, like "🎃 Halloween Picks".
    var title: String { "\(emoji) " + String(localized: "\(name) Picks") }

    static let all: [Holiday] = [
        Holiday(id: "newYear", emoji: "🎆", keyword: "new year's eve", leadDays: 10),
        Holiday(id: "valentines", emoji: "💘", keyword: "valentine's day", leadDays: 14),
        Holiday(id: "stPatricks", emoji: "🍀", keyword: "st. patrick's day", leadDays: 14),
        Holiday(id: "easter", emoji: "🐣", keyword: "easter", leadDays: 14),
        Holiday(id: "mothers", emoji: "💐", keyword: "mother's day", leadDays: 10),
        Holiday(id: "memorial", emoji: "🇺🇸", keyword: "memorial day", leadDays: 10),
        Holiday(id: "juneteenth", emoji: "✊", keyword: "juneteenth", leadDays: 10),
        Holiday(id: "pride", emoji: "🏳️‍🌈", keyword: "lgbt", leadDays: 29, trailDays: 0, broad: true),
        Holiday(id: "fathers", emoji: "👔", keyword: "father's day", leadDays: 10),
        Holiday(id: "july4", emoji: "🎇", keyword: "fourth of july", leadDays: 14),
        // A long tail: summer picks fill the weeks no other holiday covers, until Labor Day takes over.
        Holiday(id: "summer", emoji: "☀️", keyword: "summer", leadDays: 7, trailDays: 70, broad: true),
        Holiday(id: "labor", emoji: "🛠️", keyword: "labor day", leadDays: 14),
        Holiday(id: "halloween", emoji: "🎃", keyword: "halloween", leadDays: 30),
        Holiday(id: "thanksgiving", emoji: "🦃", keyword: "thanksgiving", leadDays: 14),
        Holiday(id: "christmas", emoji: "🎄", keyword: "christmas", leadDays: 30),
    ]

    /// The day of this holiday in a given year.
    func date(inYear year: Int, calendar: Calendar) -> Date? {
        func day(_ month: Int, _ day: Int) -> Date? { calendar.date(from: DateComponents(year: year, month: month, day: day)) }
        switch id {
        case "newYear": return day(12, 31)
        case "valentines": return day(2, 14)
        case "stPatricks": return day(3, 17)
        case "easter": return Self.easter(year, calendar: calendar)
        case "mothers": return calendar.date(from: DateComponents(year: year, month: 5, weekday: 1, weekdayOrdinal: 2))
        case "memorial": return calendar.date(from: DateComponents(year: year, month: 5, weekday: 2, weekdayOrdinal: -1))
        case "juneteenth": return day(6, 19)
        case "pride": return day(6, 30)
        case "fathers": return calendar.date(from: DateComponents(year: year, month: 6, weekday: 1, weekdayOrdinal: 3))
        case "summer": return day(6, 21)
        case "labor": return calendar.date(from: DateComponents(year: year, month: 9, weekday: 2, weekdayOrdinal: 1))
        case "july4": return day(7, 4)
        case "halloween": return day(10, 31)
        case "thanksgiving":
            // The fourth Thursday of November.
            return calendar.date(from: DateComponents(year: year, month: 11, weekday: 5, weekdayOrdinal: 4))
        default: return day(12, 25)
        }
    }

    /// Easter Sunday by the usual Gregorian calculation.
    private static func easter(_ year: Int, calendar: Calendar) -> Date? {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let dayOfMonth = (h + l - 7 * m + 114) % 31 + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))
    }

    /// The holiday to feature on a date: one whose run-up has started (and which hasn't been over for longer than its tail).
    /// When two overlap, the one whose day is nearest.
    static func current(on date: Date, calendar: Calendar = .current) -> Holiday? {
        let today = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: today)
        func nearest(broad: Bool) -> Holiday? {
            var best: (holiday: Holiday, daysAway: Int)?
            for holiday in all where holiday.broad == broad {
                for y in [year - 1, year, year + 1] {
                    guard let target = holiday.date(inYear: y, calendar: calendar),
                          let away = calendar.dateComponents([.day], from: today, to: target).day,
                          away <= holiday.leadDays, away >= -holiday.trailDays else { continue }
                    if best == nil || abs(away) < abs(best!.daysAway) { best = (holiday, away) }
                }
            }
            return best?.holiday
        }
        return nearest(broad: false) ?? nearest(broad: true)
    }
}

/// Picks for the holiday that's coming up: titles TMDB tags with the holiday's keyword, movies and series mixed.
@MainActor
@Observable
final class SeasonalModel {
    private(set) var holiday: Holiday?
    private(set) var items: [MediaResult] = []
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadedHoliday: String?

    /// Today. In a debug build, MINDSEERR_DATE=yyyy-MM-dd pretends it's that day, to see another holiday's row.
    private var today: Date {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["MINDSEERR_DATE"] {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: text) { return date }
        }
        #endif
        return Date()
    }

    func refresh(api: SeerrClient) async {
        let current = Holiday.current(on: today)
        holiday = current
        guard let current else { items = []; return }
        // Kept for a few hours, unless a different holiday has taken over.
        if loadedHoliday == current.id, let loadedAt, Date().timeIntervalSince(loadedAt) < 6 * 3600, !items.isEmpty { return }
        guard let keyword = await api.keywordID(for: current) else { return }
        async let movies = try? await api.keywordTitles(keyword, type: .movie)
        async let series = try? await api.keywordTitles(keyword, type: .tv)
        let (m, s) = await (movies ?? [], series ?? [])

        // Movies and series take turns, so neither crowds out the other.
        var merged: [MediaResult] = []
        var seen = Set<String>()
        for i in 0..<max(m.count, s.count) {
            for list in [m, s] where i < list.count {
                let item = list[i]
                if item.route != nil, item.posterPath != nil, seen.insert(item.uid).inserted { merged.append(item) }
            }
        }
        items = Array(merged.prefix(30))
        loadedHoliday = current.id
        loadedAt = Date()
    }
}
