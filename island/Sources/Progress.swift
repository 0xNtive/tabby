import Foundation

// MARK: - Claude's task list

/// The work plan Claude keeps with its task tools (TaskCreate / TaskUpdate, or TodoWrite in older
/// versions), replayed from the transcript: how many tasks, how many done, which one is running.
struct TaskProgress: Equatable, Sendable {
    var total: Int
    var done: Int
    var active: Int
    /// The task in progress, as Claude named it.
    var current: String?

    /// Some tasks still to do: the list describes work in progress.
    var open: Bool { done < total }
}

enum TaskParser {
    private struct Task {
        var id: String
        var subject: String
        var status: String
    }

    /// Transcript lines, oldest first. Nil when Claude made no task list.
    static func parse<Lines: Sequence>(_ lines: Lines) -> TaskProgress? where Lines.Element: StringProtocol {
        var tasks: [Task] = []
        for line in lines {
            guard line.contains("\"TaskCreate\"") || line.contains("\"TaskUpdate\"") || line.contains("\"TodoWrite\"") else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "tool_use" {
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "TaskCreate":
                    // A new plan after the last one was finished starts a new list.
                    if !tasks.isEmpty, tasks.allSatisfy({ $0.status == "completed" }) { tasks = [] }
                    let subject = text(input["activeForm"]) ?? text(input["subject"]) ?? text(input["description"]) ?? ""
                    tasks.append(Task(id: String(tasks.count + 1), subject: subject, status: "pending"))
                case "TaskUpdate":
                    let id = text(input["taskId"]) ?? (input["taskId"] as? NSNumber).map { "\($0)" } ?? ""
                    let status = text(input["status"])
                    if status == "deleted" {
                        tasks.removeAll { $0.id == id }
                    } else if let index = tasks.firstIndex(where: { $0.id == id }) {
                        if let status { tasks[index].status = status }
                        if let subject = text(input["activeForm"]) ?? text(input["subject"]) { tasks[index].subject = subject }
                    } else if !id.isEmpty {
                        // Created before the part of the transcript that was read.
                        tasks.append(Task(id: id, subject: text(input["subject"]) ?? "", status: status ?? "pending"))
                    }
                case "TodoWrite":
                    let todos = input["todos"] as? [[String: Any]] ?? []
                    tasks = todos.enumerated().map { index, todo in
                        Task(id: String(index + 1), subject: text(todo["activeForm"]) ?? text(todo["content"]) ?? "",
                             status: text(todo["status"]) ?? "pending")
                    }
                default:
                    break
                }
            }
        }
        guard !tasks.isEmpty else { return nil }
        let current = tasks.first { $0.status == "in_progress" }?.subject
        return TaskProgress(total: tasks.count,
                            done: tasks.filter { $0.status == "completed" }.count,
                            active: tasks.filter { $0.status == "in_progress" }.count,
                            current: current.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Past turns, from the transcript

/// Turn lengths read from a transcript, for sessions tabby hasn't timed yet: from each prompt to
/// the last line before the next one (so a turn that's still running isn't counted).
enum TranscriptTurns {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole = ISO8601DateFormatter()

    /// Milliseconds per finished turn, oldest first. `isPrompt`: a line where you typed a prompt.
    static func durations<Lines: Sequence>(_ lines: Lines, isPrompt: (Lines.Element) -> Bool) -> [Double]
        where Lines.Element: StringProtocol {
        var clock = Clock()
        for line in lines { clock.feed(line, isPrompt: isPrompt(line)) }
        return clock.durations
    }

    /// Fed a transcript's lines as they're written; remembers the turn that's still open.
    struct Clock {
        private(set) var durations: [Double] = []
        private var start: Date?
        private var last: String?

        mutating func feed<Line: StringProtocol>(_ line: Line, isPrompt: Bool) {
            guard let stamp = TranscriptTurns.timestamp(line) else { return }
            if isPrompt {
                if let start, let last, let end = TranscriptTurns.date(last) {
                    let ms = end.timeIntervalSince(start) * 1000
                    if ms >= 1500 { durations.append(ms) }
                    if durations.count > 40 { durations.removeFirst(durations.count - 40) }
                }
                start = TranscriptTurns.date(stamp)
                last = nil
            } else {
                last = stamp
            }
        }
    }

    static func timestamp<Line: StringProtocol>(_ line: Line) -> String? {
        guard let range = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    fileprivate static func date(_ stamp: String) -> Date? {
        fractional.date(from: stamp) ?? whole.date(from: stamp)
    }
}

// MARK: - The estimate

/// How far along a working session probably is, and how long it has left. From Claude's task
/// list when it keeps one; otherwise from how long this session's turns usually take. A
/// guesstimate, and worded as one.
struct ProgressGuess: Equatable, Sendable {
    /// 0…1; nil when there's nothing to go on.
    var fraction: Double?
    /// Seconds left, when that can be guessed.
    var remaining: TimeInterval?
    /// "2 of 5 tasks · ~3m left", "~2m left · usually 4m", "Longer than usual (4m)".
    var caption: String

    /// `elapsed`: seconds of work in this turn (waits on you excluded). `typical`: the median
    /// length of this session's turns (or of all sessions', early on).
    static func make(elapsed: TimeInterval, typical: TimeInterval?, tasks: TaskProgress?) -> ProgressGuess? {
        if let tasks, tasks.open, tasks.total >= 2 {
            let doneish = Double(tasks.done) + 0.5 * Double(min(tasks.active, tasks.total - tasks.done))
            var caption = "\(tasks.done) of \(tasks.total) tasks"
            var remaining: TimeInterval?
            if tasks.done >= 1, elapsed >= 20 {
                remaining = elapsed / doneish * (Double(tasks.total) - doneish)
                caption += " · \(Fmt.left(remaining!))"
            }
            return ProgressGuess(fraction: min(0.97, doneish / Double(tasks.total)), remaining: remaining, caption: caption)
        }
        guard let typical, typical >= 10 else { return nil }
        if elapsed < typical * 0.92 {
            let remaining = typical - elapsed
            return ProgressGuess(fraction: 0.9 * elapsed / typical, remaining: remaining,
                                 caption: "\(Fmt.left(remaining)) · usually \(Fmt.duration(typical))")
        }
        // Past the usual length: creep toward the end, never reach it.
        let over = (elapsed - typical) / typical
        return ProgressGuess(fraction: 0.9 + 0.08 * (1 - exp(-over)), remaining: nil,
                             caption: "Longer than usual (\(Fmt.duration(typical)))")
    }

    /// The median of recent turn lengths, in seconds (nil under `minimum` samples).
    static func typical(_ turnsMs: [Double], minimum: Int = 3) -> TimeInterval? {
        let turns = turnsMs.filter { $0 > 0 }.suffix(40).sorted()
        guard turns.count >= minimum else { return nil }
        let middle = turns.count / 2
        let median = turns.count % 2 == 1 ? turns[middle] : (turns[middle - 1] + turns[middle]) / 2
        return median / 1000
    }
}

extension Fmt {
    /// "<1m left", "~4m left", "~2h left".
    static func left(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "<1m left" }
        if seconds < 3600 { return "~\(Int((seconds / 60).rounded()))m left" }
        return "~\(Int((seconds / 3600).rounded()))h left"
    }

    /// Time spent so far, rounded down: "3m", "1h 5m". Nil under a minute.
    static func worked(_ seconds: TimeInterval) -> String? {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return nil }
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "40s", "4m", "1h 5m".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
