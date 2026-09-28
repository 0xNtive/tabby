import AppKit
import Darwin

/// Ends a Claude session from the island (after the inline confirmation): checks the pid is
/// still that session's Claude (`SessionEndGuard`), stops it, then closes its terminal tab where
/// the terminal allows it.
///
/// - **Terminal.app** has no AppleScript to close a tab, so once Claude is gone and the tab's
///   shell is back at its prompt (`busy` is false), the island types `exit 0` there: the shell
///   exits cleanly and Terminal closes the tab (its default for a clean exit).
/// - **iTerm2** closes the tab's session by AppleScript.
/// - **Other terminals**: Claude ends; the tab stays open.
enum SessionEnder {
    enum Outcome: Equatable, Sendable {
        /// `tabClosed`: the terminal tab went away too. `note`: what's left for you to do.
        case ended(tabClosed: Bool, note: String?)
        /// Claude had already ended.
        case gone
        case failed(String)
    }

    struct Target: Sendable {
        let pid: Int
        let sessionId: String?
        let tty: String?
        let term: String?
        let startedAtMs: Double

        init(_ session: IslandSession) {
            pid = session.pid
            sessionId = session.sessionId
            tty = session.tty
            term = session.term
            startedAtMs = session.startedAt
        }
    }

    @MainActor
    static func end(_ session: IslandSession, completion: @escaping @MainActor (Outcome) -> Void) {
        let target = Target(session)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = run(target)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(outcome) }
            }
        }
    }

    /// Blocking: call off the main thread. `registry`: Claude's ~/.claude/sessions.
    nonisolated static func run(_ target: Target, registry: URL = registryDirectory) -> Outcome {
        let observed = observe(pid: target.pid, registry: registry)
        switch SessionEndGuard.verdict(sessionId: target.sessionId, tty: target.tty,
                                       startedAtMs: target.startedAtMs, observed: observed) {
        case .gone: return .gone
        case .refuse(let reason): return .failed(reason)
        case .end: break
        }
        guard stop(pid: target.pid, startedAt: observed.startedAt) else {
            return .failed("Claude didn't stop (pid \(target.pid)). Close its tab to end it.")
        }
        guard let tty = SessionEndGuard.normalizeTTY(target.tty) else { return .ended(tabClosed: false, note: nil) }
        let kind = TerminalKind(term: target.term)
        switch kind {
        case .terminal: return closeTab(script: terminalClose, bundleId: "com.apple.Terminal", tty: tty, kind: kind)
        case .iTerm: return closeTab(script: iTermClose, bundleId: "com.googlecode.iterm2", tty: tty, kind: kind)
        case .other: return .ended(tabClosed: false, note: "Its \(kind.label) tab is still open.")
        }
    }

    // MARK: The process

    nonisolated static var registryDirectory: URL {
        ClaudePaths.dir.appendingPathComponent("sessions", isDirectory: true)
    }

    /// What's true of `pid` right now, plus what Claude's registry says about it.
    nonisolated static func observe(pid: Int, registry: URL) -> SessionEndGuard.Observed {
        var observed = SessionEndGuard.Observed(running: false)
        guard let info = kinfo(pid) else { return observed }
        observed.running = info.kp_proc.p_stat != SZOMB
        observed.command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let start = info.kp_proc.p_starttime
        observed.startedAt = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        observed.tty = ProcessProbe.tty(pid: pid)
        observed.arguments = arguments(pid: pid)
        let file = registry.appendingPathComponent("\(pid).json")
        if let data = try? Data(contentsOf: file),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            observed.registrySessionId = json["sessionId"] as? String
            observed.registryProcStart = json["procStart"] as? String
        }
        return observed
    }

    nonisolated private static func kinfo(_ pid: Int) -> kinfo_proc? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == Int32(pid) else { return nil }
        return info
    }

    nonisolated static func isRunning(_ pid: Int) -> Bool {
        guard let info = kinfo(pid) else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    /// argv of a same-user process (KERN_PROCARGS2).
    nonisolated private static func arguments(pid: Int) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 8 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }   // executable path
        while i < size && buffer[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while i < size && args.count < argc {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// SIGTERM, then SIGKILL if it's still there after 3 s (only while it is still the process
    /// that was checked: same start time).
    nonisolated private static func stop(pid: Int, startedAt: Date?) -> Bool {
        guard kill(pid_t(pid), SIGTERM) == 0 || errno == ESRCH else { return false }
        if waitForExit(pid, seconds: 3) { return true }
        if let startedAt, let info = kinfo(pid) {
            let start = info.kp_proc.p_starttime
            let now = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
            guard abs(now.timeIntervalSince(startedAt)) < 0.01 else { return true }   // a new process: ours is gone
        }
        kill(pid_t(pid), SIGKILL)
        return waitForExit(pid, seconds: 1.5)
    }

    nonisolated private static func waitForExit(_ pid: Int, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if !isRunning(pid) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return !isRunning(pid)
    }

    // MARK: The tab

    nonisolated private static func closeTab(script: String, bundleId: String, tty: String, kind: TerminalKind) -> Outcome {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else {
            return .ended(tabClosed: true, note: nil)   // the terminal isn't even running
        }
        let result = osascript(script, args: [tty])
        if result.status != 0 {
            let denied = result.error.contains("-1743") || result.error.localizedCaseInsensitiveContains("not allowed")
            NSLog("tabby island: closing the tab failed: %@", result.error)
            return .ended(tabClosed: false, note: denied
                ? "Its tab is still open: allow tabby to control \(kind.label) (Settings › Permissions) and it closes tabs too."
                : "Its \(kind.label) tab is still open.")
        }
        switch result.output {
        case "closed": return .ended(tabClosed: true, note: nil)
        case "missing": return .ended(tabClosed: false, note: nil)
        case "exited": return .ended(tabClosed: false, note: "Its tab stays open: \(kind.label)'s profile keeps tabs after the shell exits.")
        default: return .ended(tabClosed: false, note: "Its \(kind.label) tab is still open: something else runs in it.")
        }
    }

    nonisolated private static func osascript(_ source: String, args: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + args
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: err, as: UTF8.self))
    }

    /// Types `exit 0` into the tab once its shell is back at the prompt (up to ~3 s), never
    /// while anything else runs there, then checks the tab went away ("closed"), or stayed
    /// because the profile keeps tabs after the shell exits ("exited").
    private static let terminalClose = """
    on hasTab(targetTTY)
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then return true
                end repeat
            end repeat
        end tell
        return false
    end hasTab

    on run argv
        set targetTTY to item 1 of argv
        set typed to false
        tell application "Terminal"
            repeat 20 times
                set found to false
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is targetTTY then
                            set found to true
                            if not (busy of t) then
                                do script "exit 0" in t
                                set typed to true
                                exit repeat
                            end if
                        end if
                    end repeat
                    if typed then exit repeat
                end repeat
                if typed then exit repeat
                if not found then return "missing"
                delay 0.15
            end repeat
        end tell
        if not typed then return "busy"
        repeat 10 times
            delay 0.15
            if not my hasTab(targetTTY) then return "closed"
        end repeat
        return "exited"
    end run
    """

    private static let iTermClose = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is targetTTY then
                            close s
                            return "closed"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
    end run
    """
}
