import AppKit
import Foundation

/// Reads the live tabs of Terminal.app / iTerm2: each tab's title (where Claude Code keeps its AI
/// topic title, for sessions without a tabby record) and, for Terminal.app, the window showing
/// it (for the watermark). On current macOS every Terminal tab is its own window inside a tab
/// group, and Terminal's window ids are the window server's window numbers.
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
    private var windows: [String: Int] = [:]
    private var running = false
    private var lastRun = Date.distantPast
    private var backoffUntil = Date.distantPast
    private var denied = false
    /// The watermark saw a Terminal window it can't place: read again at the next chance.
    private var urgentRequested = false
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

    /// Terminal.app window of each tab, keyed by tty.
    func terminalWindows() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return windows
    }

    /// macOS refused to let the island control a terminal (Automation) on the last try.
    var automationDenied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return denied
    }

    /// Asks for a round at the next chance (at most one a second).
    func requestUrgent() {
        lock.lock()
        urgentRequested = true
        lock.unlock()
    }

    /// Starts a background round if one is due (every `every` seconds). Never blocks the caller.
    /// `urgent`: a Terminal session whose window isn't known yet (a new tab, or one moved to its
    /// own window).
    func refreshIfNeeded(terminal: Bool, iTerm: Bool, every interval: TimeInterval = 3, urgent: Bool = false) {
        guard enabled, terminal || iTerm else { return }
        lock.lock()
        let now = Date()
        let soon = urgent || urgentRequested
        guard !running, now.timeIntervalSince(lastRun) >= (soon ? 1 : interval), now >= backoffUntil else {
            lock.unlock()
            return
        }
        running = true
        lastRun = now
        urgentRequested = false
        lock.unlock()

        queue.async { [self] in
            var mergedTitles: [String: String] = [:]
            var mergedWindows: [String: Int] = [:]
            var refused = false
            // Only talk to apps that are already running; `tell application` would launch them.
            if terminal, Self.isRunning("com.apple.Terminal") {
                switch Self.execute(terminalScript) {
                case .success(let text):
                    let tabs = Self.parse(text)
                    mergedTitles.merge(tabs.titles) { $1 }
                    mergedWindows = tabs.windows
                case .failure(let error): refused = refused || error.code == -1743
                }
            }
            if iTerm, Self.isRunning("com.googlecode.iterm2") {
                switch Self.execute(iTermScript) {
                case .success(let text): mergedTitles.merge(Self.parse(text).titles) { $1 }
                case .failure(let error): refused = refused || error.code == -1743
                }
            }
            lock.lock()
            titles = mergedTitles
            windows = mergedWindows
            running = false
            denied = refused
            if refused { backoffUntil = Date().addingTimeInterval(60) }
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

    /// Lines of "window id ⇥ tty ⇥ title".
    private static func parse(_ text: String) -> (titles: [String: String], windows: [String: Int]) {
        var titles: [String: String] = [:]
        var windows: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let tty = parts[1].trimmingCharacters(in: .whitespaces)
            guard tty.hasPrefix("/dev/") else { continue }
            if let id = Int(parts[0].trimmingCharacters(in: .whitespaces)) { windows[tty] = id }
            let title = clean(String(parts[2]))
            if !title.isEmpty { titles[tty] = title }
        }
        return (titles, windows)
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    // Three Apple events in all (one per property, for every tab at once): asking tab by tab
    // took a round trip per property per tab, about 6× as long. The lines are put together
    // outside the tell block, where it costs Terminal nothing.
    private static let terminalSource = """
    tell application "Terminal"
        set ids to id of every window
        set ttys to tty of every tab of every window
        set names to custom title of every tab of every window
    end tell
    set out to ""
    repeat with i from 1 to count of ids
        set wid to item i of ids
        set wt to item i of ttys
        set wn to item i of names
        repeat with j from 1 to count of wt
            set out to out & wid & (ASCII character 9) & (item j of wt) & (ASCII character 9) & (item j of wn) & linefeed
        end repeat
    end repeat
    return out
    """

    private static let iTermSource = """
    tell application "iTerm2"
        set out to ""
        repeat with w in windows
            set wid to id of w
            repeat with t in tabs of w
                repeat with s in sessions of t
                    set out to out & wid & (ASCII character 9) & (tty of s) & (ASCII character 9) & (name of s) & linefeed
                end repeat
            end repeat
        end repeat
        return out
    end tell
    """
}
