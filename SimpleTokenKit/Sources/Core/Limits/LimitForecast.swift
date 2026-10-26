import Foundation

/// Where a Claude limit window is heading by its reset in its first minutes or hours, before a straight line from
/// the pace so far means anything (`LimitsStore.projectedPercent` switches to the line after 5% of the window).
/// The share of the limit one Claude Code token costs is read from this window (used % ÷ tokens since it opened);
/// the tokens still to come are the average of the same half-hours over the past two weeks.
public enum LimitForecast {
    /// Days of history the half-hour profile averages over
    static let profileDays = 14

    /// Projected usage at reset (%), nil without a reset, without usage yet, or without Claude Code tokens in the
    /// window or in the profile (usage from claude.ai alone, a new install). `models` limits the count to the window's
    /// models (the Fable window counts Fable only).
    public static func projectedPercent(_ w: LimitWindow, snapshot: IntradayScanner.Snapshot,
                                        models: (String) -> Bool = { _ in true }, now: Date = Date(),
                                        calendar: Calendar = .current) -> Double? {
        guard w.usedPercent > 0, let reset = w.resetsAt, reset > now else { return nil }
        let start = max(reset.addingTimeInterval(-w.spanSeconds), now.addingTimeInterval(-w.spanSeconds))

        func slotTokens(_ day: String, _ slot: Int) -> Int {
            var sum = 0
            for (model, list) in snapshot.byModel[day] ?? [:] where models(model) && slot < list.count { sum += list[slot] }
            return sum
        }
        func slot(_ date: Date) -> (day: String, index: Int) {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            return (Fmt.dayKey(date), min(47, (c.hour! * 60 + c.minute!) / 30))
        }

        // Tokens since the window opened, half-hour by half-hour from the one it opened in (counted whole) to now
        func slotStart(_ date: Date) -> Date {
            let c = calendar.dateComponents([.minute, .second], from: date)
            return date.addingTimeInterval(-Double((c.minute! % 30) * 60 + c.second!))
        }
        var spent = 0
        var t = slotStart(start)
        while t <= now {
            let s = slot(t)
            spent += slotTokens(s.day, s.index)
            t = t.addingTimeInterval(1800)
        }
        guard spent > 0 else { return nil }

        // Average tokens per half-hour of the day over the complete days before today. Idle days have no entry but
        // still count, as long as the logs reach back that far.
        guard let earliest = snapshot.days.first else { return nil }
        var profile = Array(repeating: 0.0, count: 48)
        var days = 0
        for back in 1...profileDays {
            guard let date = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let key = Fmt.dayKey(date)
            guard key >= earliest else { break }
            days += 1
            for i in 0..<48 { profile[i] += Double(slotTokens(key, i)) }
        }
        guard days > 0 else { return nil }
        profile = profile.map { $0 / Double(days) }

        // Tokens still to come: the rest of the current half-hour, then every half-hour up to the reset
        let next = slotStart(now).addingTimeInterval(1800)
        var expected = profile[slot(now).index] * min(next, reset).timeIntervalSince(now) / 1800
        t = next
        while t < reset {
            expected += profile[slot(t).index] * min(1, reset.timeIntervalSince(t) / 1800)
            t = t.addingTimeInterval(1800)
        }
        return w.usedPercent + w.usedPercent / Double(spent) * expected
    }
}
