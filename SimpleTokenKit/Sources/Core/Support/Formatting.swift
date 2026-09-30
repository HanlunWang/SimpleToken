import Foundation

/// A localized UI string. The source language is English; translations live in the app's
/// String Catalog (`App/Localizable.xcstrings`). Interpolated `String` values become `%@`,
/// `Int` values `%lld` and `Double` values `%lf` in the catalog key.
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}

/// Number, money and date formatting shared by every view.
public enum Fmt {
    /// Whether the UI runs in a Chinese localization (large numbers then use ten-thousand based units).
    public static let usesCJKUnits: Bool = {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
    }()

    /// Compact ASCII form for the menu bar: 74.2M / 1.24B / 700.0K
    public static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case 1e9...: return String(format: "%.2fB", v / 1e9)
        case 1e6...: return String(format: "%.1fM", v / 1e6)
        case 1e3...: return String(format: "%.1fK", v / 1e3)
        default: return String(n)
        }
    }

    public static func usd(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    /// Money in the UI: no cents from $1,000 up ($4,044), otherwise two decimals.
    /// Formatters are cached: creating one initialises ICU, and hover redraws call this often.
    public static func money(_ v: Double) -> String {
        let f = v >= 1000 ? NumberFormatter.moneyWhole : NumberFormatter.moneyCents
        return "$" + (f.string(from: NSNumber(value: v)) ?? String(v))
    }

    /// Hours and minutes in the local time zone.
    public static func clock(_ date: Date) -> String { DateFormatter.clock.string(from: date) }

    /// Short token count. English: 5.21 B / 23.4 M / 3,512. Chinese uses ten-thousand based units from the catalog (unit.10K, unit.100M).
    /// The unit is separated by a space so `BigNumber` can render it smaller.
    public static func short(_ n: Double) -> String {
        let v = n.rounded()
        if usesCJKUnits {
            if v >= 1e8 { return String(format: v >= 1e10 ? "%.1f" : "%.2f", v / 1e8) + " " + L("unit.100M") }
            if v >= 1e4 { return grouped(Int((v / 1e4).rounded())) + " " + L("unit.10K") }
            return grouped(Int(v))
        }
        if v >= 1e9 { return String(format: v >= 1e11 ? "%.0f B" : v >= 1e10 ? "%.1f B" : "%.2f B", v / 1e9) }
        if v >= 1e6 { return String(format: v >= 1e8 ? "%.0f M" : "%.1f M", v / 1e6) }
        if v >= 1e4 { return String(format: "%.1f K", v / 1e3) }
        return grouped(Int(v))
    }

    /// Token count following the short / exact setting.
    public static func tokens(_ n: Double, exact: Bool) -> String {
        exact ? grouped(Int(n.rounded())) : short(n)
    }

    /// Formats a value for a metric (axis ticks pass `exact: false` and are always short).
    public static func metric(_ v: Double, _ metric: UsageMetric, exact: Bool) -> String {
        switch metric {
        case .tokens: tokens(v, exact: exact)
        case .cost: money(v)
        case .messages: L("\(grouped(Int(v.rounded()))) msgs")
        }
    }

    /// 30 s / 2 min / 1 min 30 s
    public static func seconds(_ s: Int) -> String {
        if s < 60 { return L("\(s) s") }
        if s % 60 == 0 { return L("\(s / 60) min") }
        return L("\(s / 60) min \(s % 60) s")
    }

    /// Month and day of a day key: "Sep 14" in English
    public static func shortDate(_ dayKey: String) -> String {
        guard let date = dateFromKey(dayKey) else { return dayKey }
        return DateFormatter.monthDay.string(from: date)
    }

    /// Year, month, day and weekday of a day key: "Mon, Sep 14, 2026"
    public static func longDate(_ dayKey: String) -> String {
        guard let date = dateFromKey(dayKey) else { return dayKey }
        return DateFormatter.longDay.string(from: date)
    }

    /// Month name for calendar labels: "Sep" in English
    public static func monthName(_ date: Date) -> String {
        DateFormatter.monthOnly.string(from: date)
    }

    /// The app's UI locale (the localization macOS picked for this app, not the system region)
    public static let uiLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    /// Calendar whose symbols follow the UI language
    private static let uiCalendar: Calendar = {
        var cal = Calendar.current
        cal.locale = uiLocale
        return cal
    }()

    /// Short weekday names starting on Monday: Mon…Sun in English
    public static let weekdaysFromMonday: [String] = {
        let symbols = uiCalendar.shortWeekdaySymbols   // Sunday first
        return Array(symbols[1...]) + [symbols[0]]
    }()

    /// Very short weekday names starting on Monday: M T W… in English
    public static let weekdayInitialsFromMonday: [String] = {
        let symbols = uiCalendar.veryShortStandaloneWeekdaySymbols
        return Array(symbols[1...]) + [symbols[0]]
    }()

    /// Weekday name of a date (Monday = 0 … Sunday = 6 in `weekdaysFromMonday`).
    public static func weekday(_ date: Date) -> String {
        weekdaysFromMonday[(Calendar.current.component(.weekday, from: date) + 5) % 7]
    }

    /// Exact number with grouping: 74,208,291
    public static func exact(_ n: Int) -> String { grouped(n) }

    static func grouped(_ n: Int) -> String {
        NumberFormatter.grouping.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Local day key (tokscale uses the system time zone too).
    public static func dayKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func monthKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    static func dateFromKey(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }
}

extension DateFormatter {
    nonisolated(unsafe) static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func template(_ t: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Fmt.uiLocale
        f.setLocalizedDateFormatFromTemplate(t)
        return f
    }

    nonisolated(unsafe) static let monthDay = template("MMMd")
    nonisolated(unsafe) static let longDay = template("yMMMdEEE")
    nonisolated(unsafe) static let monthOnly = template("MMM")
    /// Reset times: today → "14:30", this week → "Sun 14:30", later → "Oct 7 14:30"
    nonisolated(unsafe) public static let resetToday = template("HHmm")
    nonisolated(unsafe) public static let resetWeek = template("EEEHHmm")
    nonisolated(unsafe) public static let resetLater = template("MMMdHHmm")
}

extension NumberFormatter {
    nonisolated(unsafe) static let moneyWhole: NumberFormatter = money(fraction: 0)
    nonisolated(unsafe) static let moneyCents: NumberFormatter = money(fraction: 2)

    private static func money(fraction: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        return f
    }

    nonisolated(unsafe) static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()
}
