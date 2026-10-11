import Darwin
import Foundation

// MARK: - State (from the tabby CLI's awake.json)

/// Awake: the Mac keeps running with the lid closed until a time, or until every session is
/// done. `tabby awake` writes <Claude folder>/tabby/awake.json; a watcher it starts turns sleep
/// back on. The island only reads the file and runs the CLI.
struct AwakeState: Equatable, Sendable {
    var on: Bool
    var token: String
    var startedAt: Date
    var until: Date
    var untilDone: Bool
    var minBattery: Int
    var watcherPid: Int32?
    var endedAt: Date?
    /// time, done, battery, off, external
    var reason: String?
    /// Sessions that worked while it was on (set when it ends).
    var worked: Int?
    /// False when tabby couldn't turn sleep back on.
    var restored: Bool

    static var file: URL { ClaudePaths.tabby.appendingPathComponent("awake.json") }

    static func read() -> AwakeState? {
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func date(_ key: String) -> Date? {
            (json[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        guard let startedAt = date("startedAt"), let until = date("until") else { return nil }
        return AwakeState(on: (json["on"] as? Bool) ?? false,
                          token: (json["token"] as? String) ?? "",
                          startedAt: startedAt, until: until,
                          untilDone: (json["untilDone"] as? Bool) ?? false,
                          minBattery: (json["minBattery"] as? NSNumber)?.intValue ?? 10,
                          watcherPid: (json["watcherPid"] as? NSNumber)?.int32Value,
                          endedAt: date("endedAt"),
                          reason: json["reason"] as? String,
                          worked: (json["worked"] as? NSNumber)?.intValue,
                          restored: (json["restored"] as? Bool) ?? true)
    }

    func left(now: Date) -> TimeInterval { max(0, until.timeIntervalSince(now)) }

    /// How much of the time is left, 1…0 (the ring empties as it runs).
    func fraction(now: Date) -> Double {
        let total = until.timeIntervalSince(startedAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, left(now: now) / total))
    }

    /// On, but nobody is keeping time: the watcher is gone (a restart) or the end was missed.
    func needsCheck(now: Date) -> Bool {
        guard on else { return false }
        if now > until.addingTimeInterval(30) { return true }
        guard let pid = watcherPid, pid > 0 else { return true }
        return !(kill(pid, 0) == 0 || errno == EPERM)
    }

    /// "every session is done", "time's up"…
    var reasonText: String {
        switch reason {
        case "done": return "every session is done"
        case "time": return "time's up"
        case "battery": return "battery low"
        case "external": return "sleep was turned on elsewhere"
        default: return "turned off"
        }
    }

    /// Snapshot renders for the website show US times ("3:40 AM") whatever this Mac uses, at a
    /// fixed moment of a night (so the times in a render agree with each other).
    static var locale: Locale?
    static var fixedNow: Date?
    static var now: Date { fixedNow ?? Date() }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        if let locale { formatter.locale = locale }
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// "3h 12m", "40m"
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// What `tabby awake --json` adds: whether the permission is in place, and the battery.
struct AwakeInfo: Decodable, Equatable, Sendable {
    struct Battery: Decodable, Equatable, Sendable {
        var present: Bool
        var ac: Bool
        var pct: Int?
    }

    var allowed: Bool
    var battery: Battery?

    static func parse(_ output: String) -> AwakeInfo? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        return try? JSONDecoder().decode(AwakeInfo.self, from: Data(output[start...].utf8))
    }
}
