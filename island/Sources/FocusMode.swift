import Foundation

// Focus mode (`focusMode` in config.json): while Claude works in a Terminal window you're not
// in, that window shows only its topic and what's running (FocusCover.swift draws it); what
// Claude writes stays hidden until it needs you, it's your turn, or you click the window.
// With `focusIdle` (on unless turned off), a window stays covered when it's your turn, and its
// cover shows the gist of Claude's reply instead of the reply itself.

// MARK: - The rule

enum FocusRule {
    /// Whether focus mode covers a session's window right now. Covered while Claude works;
    /// open when it needs you (waiting, error), when it's your turn (idle), and whenever you're
    /// working in that window (Terminal is the active app and this is its front window).
    /// `idle`: stay covered when it's your turn too (the cover then shows a "Your turn" button).
    static func covers(status: SessionStatus, windowIsFront: Bool, terminalActive: Bool, idle: Bool = false) -> Bool {
        if windowIsFront && terminalActive { return false }
        return status == .busy || (idle && status == .idle)
    }
}

// MARK: - Subagents

/// One of Claude's subagents (an Agent/Task tool call) while it runs.
struct FocusAgent: Equatable, Sendable {
    var id: String
    /// What it was asked to do: the Agent call's `description`.
    var label: String
    /// "Explore", "general-purpose", "fork"…
    var kind: String?
    /// What it did last ("Reading tile.js", "Run the tests"), if its transcript shows a tool call.
    var tool: String?
    /// Seconds since 1970.
    var startedAt: TimeInterval
}

/// Finds a session's running subagents. Claude Code writes each one's transcript to
/// `<session transcript without .jsonl>/subagents/agent-<id>.jsonl`, with the call's
/// description and type in `agent-<id>.meta.json`. A subagent runs until its transcript ends
/// with a final answer (an assistant message that stopped with `end_turn` and calls no tool),
/// an API error, or "[Request interrupted by user]". System notifications delivered after the
/// end don't count. An answer with no stop reason is text written mid-turn, or a final answer
/// from Claude Code before 2.1.279: it counts as finished once the transcript has been quiet a
/// while. The parent's own transcript can't tell: a background agent's tool result arrives at
/// once.
///
/// Used from the store's loader queue only; files are re-read only when they change.
final class SubagentScanner: @unchecked Sendable {
    private struct Entry {
        var size: UInt64
        var mtime: Date
        var running: Bool
        /// Its last answer had no stop reason: finished once the file is quiet this long.
        var finishesWhenQuiet: TimeInterval?
        var tool: String?
        var label: String?
        var kind: String?
        var startedAt: TimeInterval
        var seenAt: Date
    }

    /// A transcript untouched this long belongs to a subagent that was stopped or crashed (a
    /// long Bash call can keep a live one quiet for minutes).
    static let staleAfter: TimeInterval = 15 * 60
    private static let tailBytes: UInt64 = 64 * 1024

    private let fm = FileManager.default
    private var cache: [String: Entry] = [:]

    /// The running subagents of the session whose transcript is at `transcript`, oldest first.
    func running(transcript: String, now: Date = Date()) -> [FocusAgent] {
        let dir = (transcript as NSString).deletingPathExtension + "/subagents"
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var agents: [FocusAgent] = []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            let path = dir + "/" + name
            guard let attributes = try? fm.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let mtime = attributes[.modificationDate] as? Date,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { continue }
            guard now.timeIntervalSince(mtime) < Self.staleAfter else {
                cache[path] = nil
                continue
            }
            var entry: Entry
            if let cached = cache[path], cached.size == size, cached.mtime == mtime {
                entry = cached
            } else {
                let state = Self.analyze(Self.lines(ofTail: Self.tail(path, size: size)))
                let meta = cache[path].map { ($0.label, $0.kind) } ?? Self.meta(path)
                let started = cache[path]?.startedAt
                    ?? ((attributes[.creationDate] as? Date) ?? mtime).timeIntervalSince1970
                entry = Entry(size: size, mtime: mtime, running: state.running, finishesWhenQuiet: state.finishesWhenQuiet,
                              tool: state.tool, label: meta.0, kind: meta.1, startedAt: started, seenAt: now)
            }
            entry.seenAt = now
            cache[path] = entry
            let quietDone = entry.finishesWhenQuiet.map { now.timeIntervalSince(mtime) >= $0 } ?? false
            guard entry.running, !quietDone else { continue }
            agents.append(FocusAgent(id: String(name.dropFirst(6).dropLast(6)), label: entry.label ?? "Subagent",
                                     kind: entry.kind, tool: entry.tool, startedAt: entry.startedAt))
        }
        cache = cache.filter { now.timeIntervalSince($0.value.seenAt) < 120 }
        return agents.sorted { $0.startedAt < $1.startedAt }
    }

    /// Whether a transcript's last lines are still going, and the last tool it called. `quiet`:
    /// how long the file has gone unchanged.
    static func state<Lines: Sequence>(ofLines lines: Lines, quiet: TimeInterval = 0) -> (running: Bool, tool: String?)
    where Lines.Element: StringProtocol {
        let result = analyze(lines)
        let quietDone = result.finishesWhenQuiet.map { quiet >= $0 } ?? false
        return (result.running && !quietDone, result.running && !quietDone ? result.tool : nil)
    }

    /// `finishesWhenQuiet`: it ends with an answer that has no stop reason, which is final only if
    /// nothing follows for this long.
    static func analyze<Lines: Sequence>(_ lines: Lines) -> (running: Bool, tool: String?, finishesWhenQuiet: TimeInterval?)
    where Lines.Element: StringProtocol {
        var running: Bool?
        var threshold: TimeInterval?
        for line in Array(lines).reversed() {
            guard line.contains("\"message\""),
                  let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = object["type"] as? String, type == "assistant" || type == "user",
                  let message = object["message"] as? [String: Any] else { continue }
            if running == nil {
                if type == "user" {
                    let text = userText(message)
                    // Delivered after it finished (or while it works): not a turn of its own.
                    if text.hasPrefix("[SYSTEM NOTIFICATION") || text.contains("<task-notification>") { continue }
                    if text.hasPrefix("[Request interrupted by user") { return (false, nil, nil) }
                } else {
                    if object["isApiErrorMessage"] as? Bool == true || message["model"] as? String == "<synthetic>" {
                        return (false, nil, nil)
                    }
                    if lastToolName(message) == nil {
                        switch message["stop_reason"] as? String {
                        case "end_turn"?, "stop_sequence"?: return (false, nil, nil)
                        case nil: threshold = quietThreshold(version: object["version"] as? String)
                        default: break
                        }
                    }
                }
                running = true
            }
            if type == "assistant", let tool = lastToolStep(message) { return (true, tool, threshold) }
        }
        return (running ?? true, nil, threshold)
    }

    /// Before 2.1.279, Claude Code wrote some final answers with no stop reason; since then that
    /// shape is always text written mid-turn, and a long tool call can follow it minutes later.
    static func quietThreshold(version: String?) -> TimeInterval {
        let parts = (version ?? "").split(separator: ".").map { Int($0) ?? 0 }
        let old = parts.count == 3 && (parts[0], parts[1], parts[2]) < (2, 1, 279)
        return old ? 60 : 600
    }

    private static func userText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [Any] else { return "" }
        for case let block as [String: Any] in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String { return text }
        }
        return ""
    }

    private static func lines(ofTail tail: (text: String, midFile: Bool)) -> [Substring] {
        var lines = tail.text.split(separator: "\n", omittingEmptySubsequences: true)
        if tail.midFile, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// The last tool call, in words ("Editing tile.js").
    private static func lastToolStep(_ message: [String: Any]) -> String? {
        guard let blocks = message["content"] as? [Any] else { return nil }
        for case let block as [String: Any] in blocks.reversed() where block["type"] as? String == "tool_use" {
            guard let name = block["name"] as? String else { continue }
            return ActivityDescriber.describe(tool: name, input: block["input"] as? [String: Any] ?? [:])
        }
        return nil
    }

    private static func lastToolName(_ message: [String: Any]) -> String? {
        guard let blocks = message["content"] as? [Any] else { return nil }
        for block in blocks.reversed() {
            if let block = block as? [String: Any], block["type"] as? String == "tool_use", let name = block["name"] as? String {
                return name
            }
        }
        return nil
    }

    private static func tail(_ path: String, size: UInt64) -> (text: String, midFile: Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ("", false) }
        defer { try? handle.close() }
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return (String(decoding: data, as: UTF8.self), start > 0)
    }

    private static func meta(_ transcript: String) -> (String?, String?) {
        let path = (transcript as NSString).deletingPathExtension + ".meta.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        let label = (json["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty == false ? label : nil, json["agentType"] as? String)
    }
}
