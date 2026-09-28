import Foundation

// Focus mode (`focusMode` in config.json): while Claude works in a Terminal window you're not
// in, that window shows only its topic and what's running (FocusCover.swift draws it); what
// Claude writes stays hidden until it needs you, it's your turn, or you click the window.

// MARK: - The rule

enum FocusRule {
    /// Whether focus mode covers a session's window right now. Covered while Claude works;
    /// open when it needs you (waiting, error), when it's your turn (idle), and whenever you're
    /// working in that window (Terminal is the active app and this is its front window).
    static func covers(status: SessionStatus, windowIsFront: Bool, terminalActive: Bool) -> Bool {
        if windowIsFront && terminalActive { return false }
        return status == .busy
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
    /// The tool it used last ("Bash", "Edit"), if its transcript shows one.
    var tool: String?
    /// Seconds since 1970.
    var startedAt: TimeInterval
}

/// Finds a session's running subagents. Claude Code writes each one's transcript to
/// `<session transcript without .jsonl>/subagents/agent-<id>.jsonl`, with the call's
/// description and type in `agent-<id>.meta.json`. A subagent runs until its transcript ends
/// with a final answer (an assistant message that stopped with `end_turn` and calls no tool).
/// The parent's own transcript can't tell: a background agent's tool result arrives at once.
///
/// Used from the store's loader queue only; files are re-read only when they change.
final class SubagentScanner: @unchecked Sendable {
    private struct Entry {
        var size: UInt64
        var mtime: Date
        var running: Bool
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
                let state = Self.state(ofTail: Self.tail(path, size: size))
                let meta = cache[path].map { ($0.label, $0.kind) } ?? Self.meta(path)
                let started = cache[path]?.startedAt
                    ?? ((attributes[.creationDate] as? Date) ?? mtime).timeIntervalSince1970
                entry = Entry(size: size, mtime: mtime, running: state.running, tool: state.tool,
                              label: meta.0, kind: meta.1, startedAt: started, seenAt: now)
            }
            entry.seenAt = now
            cache[path] = entry
            guard entry.running else { continue }
            agents.append(FocusAgent(id: String(name.dropFirst(6).dropLast(6)), label: entry.label ?? "Subagent",
                                     kind: entry.kind, tool: entry.tool, startedAt: entry.startedAt))
        }
        cache = cache.filter { now.timeIntervalSince($0.value.seenAt) < 120 }
        return agents.sorted { $0.startedAt < $1.startedAt }
    }

    /// Whether a transcript's last lines are still going, and the last tool it called.
    static func state<Lines: Sequence>(ofLines lines: Lines) -> (running: Bool, tool: String?) where Lines.Element: StringProtocol {
        var running: Bool?
        for line in Array(lines).reversed() {
            guard line.contains("\"message\""),
                  let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = object["type"] as? String, type == "assistant" || type == "user",
                  let message = object["message"] as? [String: Any] else { continue }
            let tool = type == "assistant" ? lastToolName(message) : nil
            if running == nil {
                if type == "assistant", tool == nil, message["stop_reason"] as? String == "end_turn" { return (false, nil) }
                running = true
            }
            if let tool { return (true, tool) }
        }
        return (running ?? true, nil)
    }

    private static func state(ofTail tail: (text: String, midFile: Bool)) -> (running: Bool, tool: String?) {
        var lines = tail.text.split(separator: "\n", omittingEmptySubsequences: true)
        if tail.midFile, !lines.isEmpty { lines.removeFirst() }
        return state(ofLines: lines)
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
