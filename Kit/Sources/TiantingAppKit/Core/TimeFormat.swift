import Foundation

// Time display (PRD-core F-MSG-06 rule 4): today HH:mm, yesterday "昨天 HH:mm", this year MM-DD HH:mm, earlier
// YYYY-MM-DD HH:mm. Dividers appear when more than 5 minutes separate two messages.

private func parts(_ ms: Int64, _ calendar: Calendar) -> DateComponents {
    calendar.dateComponents(
        [.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
}

private func two(_ n: Int?) -> String {
    String(format: "%02d", n ?? 0)
}

public func formatTime(_ ts: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
    let d = parts(ts, calendar)
    let hm = "\(two(d.hour)):\(two(d.minute))"
    let today = calendar.startOfDay(for: now)
    let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
    if date >= today { return hm }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return "昨天 \(hm)" }
    if d.year == calendar.component(.year, from: now) { return "\(two(d.month))-\(two(d.day)) \(hm)" }
    return "\(d.year ?? 0)-\(two(d.month))-\(two(d.day)) \(hm)"
}

/// MM-DD HH:mm, local time.
public func formatMonthDayTime(_ ts: Int64, calendar: Calendar = .current) -> String {
    let d = parts(ts, calendar)
    return "\(two(d.month))-\(two(d.day)) \(two(d.hour)):\(two(d.minute))"
}

/// YYYY-MM-DD HH:mm, local time.
public func formatDateTime(_ ts: Int64, calendar: Calendar = .current) -> String {
    "\(parts(ts, calendar).year ?? 0)-\(formatMonthDayTime(ts, calendar: calendar))"
}

public let dividerGapMs: Int64 = 5 * 60 * 1000

public func needsDivider(previous: Int64?, ts: Int64) -> Bool {
    guard let previous else { return true }
    return ts - previous > dividerGapMs
}
