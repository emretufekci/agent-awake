import Foundation

// MARK: - Usage-limit message parsing

/// Understands messages such as:
///   Claude: "5-hour limit reached ∙ resets 3pm (Europe/Istanbul)", "You've hit your limit · resets Nov 25, 3:30pm",
///           "Claude AI usage limit reached|1763650800"
///   Codex:  "You've hit your usage limit … try again in 2 hours 13 minutes", "… try again at 3:45 PM"
enum LimitParser {
    static func isLimitLine(_ line: String) -> Bool {
        let l = line.lowercased()
        return (l.contains("limit") && (l.contains("reached") || l.contains("hit your") || l.contains("exceeded")))
            && (l.contains("reset") || l.contains("try again") || l.range(of: #"\|\d{10}"#, options: .regularExpression) != nil)
    }

    static func resetDate(in line: String, now: Date = Date()) -> Date? {
        let l = line.lowercased()
        // 1) Unix epoch: "...limit reached|1763650800"
        if let r = l.range(of: #"\|(\d{10})"#, options: .regularExpression),
           let t = Double(l[r].dropFirst()) { return Date(timeIntervalSince1970: t) }

        // 2) Relative: "try again in 2 hours 13 minutes" / "resets in 4h 5m"
        if let r = l.range(of: #"(try again|resets?) in "#, options: .regularExpression) {
            let rest = String(l[r.upperBound...])
            var secs = 0.0
            let re = try! NSRegularExpression(pattern: #"(\d+)\s*(days?|d\b|hours?|hrs?|h\b|minutes?|mins?|m\b|seconds?|secs?|s\b)"#)
            for m in re.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                let n = Double(rest[Range(m.range(at: 1), in: rest)!]) ?? 0
                let u = rest[Range(m.range(at: 2), in: rest)!]
                secs += n * (u.hasPrefix("d") ? 86400 : u.hasPrefix("h") ? 3600 : u.hasPrefix("m") ? 60 : 1)
            }
            if secs > 0 { return now.addingTimeInterval(secs) }
        }

        // 3) Absolute: "resets 3pm", "resets at 15:00", "try again at nov 25th, 2026 3:45 pm"
        guard let r = l.range(of: #"(resets?( at)?|try again at) "#, options: .regularExpression) else { return nil }
        let rest = String(l[r.upperBound...])
        let re = try! NSRegularExpression(pattern:
            #"^(?:([a-z]{3,9})\.? (\d{1,2})(?:st|nd|rd|th)?,?(?: (\d{4}))?,?(?: at)? )?(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?:\s*\(([^)]+)\))?"#)
        guard let m = re.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: rest).map { String(rest[$0]) } }
        guard var hour = Int(g(4) ?? "") else { return nil }
        let minute = Int(g(5) ?? "0") ?? 0
        if let ap = g(6) {
            if ap.hasPrefix("p") && hour < 12 { hour += 12 }
            if ap.hasPrefix("a") && hour == 12 { hour = 0 }
        }
        guard hour < 24, minute < 60 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        if let tzName = g(7), let tz = TimeZone(identifier: tzName.trimmingCharacters(in: .whitespaces)
            .split(separator: "/").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "/")) {
            cal.timeZone = tz
        }
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = hour; c.minute = minute; c.second = 0
        var explicitDay = false
        if let mon = g(1), let day = Int(g(2) ?? "") {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            if let mi = months.firstIndex(where: { mon.hasPrefix($0) }) {
                c.month = mi + 1; c.day = day; explicitDay = true
                if let y = Int(g(3) ?? "") { c.year = y }
            }
        }
        guard var date = cal.date(from: c) else { return nil }
        if date < now.addingTimeInterval(-600) {
            date = cal.date(byAdding: explicitDay ? .year : .day, value: 1, to: date) ?? date
        }
        return date
    }
}

