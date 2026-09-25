import AppKit
import Foundation

/// Reads the live tab titles of Terminal.app / iTerm2 (where Claude Code keeps its AI topic
/// title) so sessions without a tabby record still get a meaningful name.
///
/// NSAppleScript is not thread-safe, so every script runs on one private serial queue.
/// Rounds are throttled to one every 3 s, and back off for a minute if Automation is denied.
final class TerminalTitleReader: @unchecked Sendable {
    private struct ScriptError: Error {
        let code: Int
    }

    private let queue = DispatchQueue(label: "dev.tabby.island.titles", qos: .utility)
    private let lock = NSLock()
    private var titles: [String: String] = [:]
    private var running = false
    private var lastRun = Date.distantPast
    private var backoffUntil = Date.distantPast
    private let enabled: Bool

    // Compiled once, touched only on `queue`.
    private lazy var terminalScript = NSAppleScript(source: Self.terminalSource)
    private lazy var iTermScript = NSAppleScript(source: Self.iTermSource)

    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// Latest titles keyed by tty ("/dev/ttys003"), already stripped of status glyphs.
    func current() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return titles
    }

    /// Starts a background round if one is due. Never blocks the caller.
    func refreshIfNeeded(terminal: Bool, iTerm: Bool) {
        guard enabled, terminal || iTerm else { return }
        lock.lock()
        let now = Date()
        guard !running, now.timeIntervalSince(lastRun) >= 3, now >= backoffUntil else {
            lock.unlock()
            return
        }
        running = true
        lastRun = now
        lock.unlock()

        queue.async { [self] in
            var merged: [String: String] = [:]
            var denied = false
            // Only talk to apps that are already running; `tell application` would launch them.
            if terminal, Self.isRunning("com.apple.Terminal") {
                switch Self.execute(terminalScript) {
                case .success(let text): merged.merge(Self.parse(text)) { $1 }
                case .failure(let error): denied = denied || error.code == -1743
                }
            }
            if iTerm, Self.isRunning("com.googlecode.iterm2") {
                switch Self.execute(iTermScript) {
                case .success(let text): merged.merge(Self.parse(text)) { $1 }
                case .failure(let error): denied = denied || error.code == -1743
                }
            }
            lock.lock()
            titles = merged
            running = false
            if denied { backoffUntil = Date().addingTimeInterval(60) }
            lock.unlock()
        }
    }

    /// Strips Claude/tabby status glyphs, markers and spinner frames from the front of a title.
    static func clean(_ title: String) -> String {
        title
            .replacingOccurrences(of: "^[\\s✳◐-◓⠀-⣿✢-✽·*🔔⚠\\x{FE0F}🔴🟠🟡🟢🔵🟣🟤⚪⚫]+",
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func execute(_ script: NSAppleScript?) -> Result<String, ScriptError> {
        guard let script else { return .failure(ScriptError(code: 0)) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return .failure(ScriptError(code: (error[NSAppleScript.errorNumber] as? Int) ?? 0))
        }
        return .success(result.stringValue ?? "")
    }

    private static func parse(_ text: String) -> [String: String] {
        var titles: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let tty = parts[0].trimmingCharacters(in: .whitespaces)
            let title = clean(String(parts[1]))
            if tty.hasPrefix("/dev/"), !title.isEmpty { titles[tty] = title }
        }
        return titles
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    // `tab` is a Terminal class name inside the tell block, so the separator is ASCII 9.
    private static let terminalSource = """
    tell application "Terminal"
        set out to ""
        repeat with w in windows
            repeat with t in tabs of w
                set out to out & (tty of t) & (ASCII character 9) & (custom title of t) & linefeed
            end repeat
        end repeat
        return out
    end tell
    """

    private static let iTermSource = """
    tell application "iTerm2"
        set out to ""
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    set out to out & (tty of s) & (ASCII character 9) & (name of s) & linefeed
                end repeat
            end repeat
        end repeat
        return out
    end tell
    """
}
