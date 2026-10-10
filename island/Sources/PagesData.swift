import Foundation

// MARK: - Pages of the expanded island

/// What the expanded island shows under its toolbar: the running sessions, the ones you ran
/// before (History), or the processes your terminals left running (Processes).
enum IslandPage: Equatable, Sendable {
    case sessions, history, processes

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .history: return "History"
        case .processes: return "Processes"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "rectangle.stack"
        case .history: return "clock.arrow.circlepath"
        case .processes: return "cpu"
        }
    }

    /// Row ids in the list's hover tracking: "h:<session>", "p:<process>"; session rows have none.
    func rowId(_ id: String) -> String {
        switch self {
        case .sessions: return id
        case .history: return "h:\(id)"
        case .processes: return "p:\(id)"
        }
    }

    static func isPageRow(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix("h:") || id.hasPrefix("p:")
    }
}

// MARK: - Data (from the tabby CLI)

/// A session you ran before (`tabby history --json`).
struct PastSession: Decodable, Equatable, Identifiable, Sendable {
    var sessionId: String
    var title: String
    var project: String?
    var cwd: String?
    var summary: String?
    var lastPrompt: String?
    var lastAt: Double
    var live: Bool
    var dot: String?
    var accent: String?
    var resumable: Bool

    var id: String { sessionId }

    /// "wildcat · Testing the Windows build on a second PC"
    var detail: String {
        let about = summary ?? lastPrompt.map { "You asked: \($0)" }
        return [project, about].compactMap { $0 }.joined(separator: " · ")
    }

    /// Today, Yesterday, This week, Earlier.
    func day(now: Date) -> String {
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: lastAt / 1000)
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if now.timeIntervalSince(date) < 7 * 86_400 { return "This week" }
        return "Earlier"
    }

    static func parse(_ output: String) -> [PastSession]? {
        guard let start = output.firstIndex(of: "[") else { return nil }
        return try? JSONDecoder().decode([PastSession].self, from: Data(output[start...].utf8))
    }
}

/// A group of processes started from a terminal or by Claude (`tabby procs --json`).
struct ProcessItem: Decodable, Equatable, Identifiable, Sendable {
    struct Owner: Decodable, Equatable, Sendable {
        var kind: String
        var live: Bool
        var sessionId: String?
        var title: String?
        var status: String?
    }

    var id: String
    var pid: Int
    var label: String
    var ports: [Int]
    var cpu: Double
    var memMB: Int
    var startedAt: Double
    var count: Int
    var owner: Owner
    var leftover: Bool
    var stale: Bool
    var why: String
    var project: String?

    /// ":5173", ":3000, :3001"
    var portText: String? { ports.isEmpty ? nil : ports.prefix(3).map { ":\($0)" }.joined(separator: " ") }

    /// "wildcat · Printer Setup · session idle 3 h"
    var detail: String {
        var parts: [String] = []
        if let project { parts.append(project) }
        if let title = owner.title, title.lowercased() != project?.lowercased() { parts.append(title) }
        return parts.joined(separator: " · ")
    }

    var symbol: String { ports.isEmpty ? (leftover ? "moon.zzz.fill" : "gearshape.2.fill") : "network" }
}

struct ProcessScan: Decodable, Equatable, Sendable {
    struct Totals: Decodable, Equatable, Sendable {
        var count: Int
        var memMB: Int
        var cpu: Double
    }

    var at: Double
    var items: [ProcessItem]
    var stale: Totals

    static func parse(_ output: String) -> ProcessScan? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        return try? JSONDecoder().decode(ProcessScan.self, from: Data(output[start...].utf8))
    }
}

struct StopResult: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        var id: String
        var label: String
        var error: String?
    }

    var stopped: [Entry]
    var failed: [Entry]
    var memMB: Int
    var cpu: Double

    static func parse(_ output: String) -> StopResult? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        return try? JSONDecoder().decode(StopResult.self, from: Data(output[start...].utf8))
    }

    /// "Stopped 3 · freed 1.2 GB"
    var message: String {
        if stopped.isEmpty && failed.isEmpty { return "Nothing left to stop" }
        var text = stopped.isEmpty ? "" : "Stopped \(stopped.count == 1 ? stopped[0].label : "\(stopped.count)") · freed \(Fmt.memory(memMB))"
        if !failed.isEmpty {
            text += (text.isEmpty ? "" : "; ") + "couldn't stop \(failed.map(\.label).joined(separator: ", "))"
        }
        return text
    }
}

extension Fmt {
    /// "456 MB", "1.2 GB"
    static func memory(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }
}
