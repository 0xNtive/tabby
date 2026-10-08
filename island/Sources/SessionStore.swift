import AppKit
import Darwin
import Foundation

struct StoreSnapshot: Equatable, Sendable {
    /// False until the first load from disk has landed.
    var loaded = false
    var sessions: [IslandSession] = []
    var themes: [ThemeInfo] = []
    /// Theme menu sections, in tabby's order (Signature, Calm, Classic, Vivid, Light, High contrast).
    var groups: [ThemeGroup] = []
    var defaultThemeId: String?
    var globalThemeId: String?
    var config = IslandConfig()
    /// config.json as read, for settings the user is changing (see PendingConfig).
    var configRaw: [String: ConfigValue] = [:]
    var cli = CLIConfig(node: "/opt/homebrew/bin/node", cli: "")
    /// macOS refused to let the island control Terminal (Automation), last time it asked.
    var automationDenied = false
    /// Every Terminal.app window with a tab, when the watermark or focus mode is on.
    var terminalWindowIds: Set<Int> = []
    /// A tile in progress, whoever started it.
    var tiling: TileProgress?
}

// MARK: - Store (main actor)

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var snapshot = StoreSnapshot()

    private let loader: SnapshotLoader
    private let queue = DispatchQueue(label: "dev.tabby.island.loader", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private let fixed: Bool

    /// `automation: false` skips AppleScript title reads (used for smoke tests).
    init(automation: Bool = true) {
        loader = SnapshotLoader(automation: automation)
        fixed = false
    }

    /// A store frozen on the given data (snapshot renders of demo sessions).
    init(fixed snapshot: StoreSnapshot) {
        loader = SnapshotLoader(automation: false)
        fixed = true
        self.snapshot = snapshot
    }

    func start() {
        guard !fixed else { return }
        refresh()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !fixed, !inFlight else { return }
        inFlight = true
        let loader = self.loader
        queue.async { [weak self] in
            let next = loader.load()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight = false
                    if next != self.snapshot { self.snapshot = next }
                }
            }
        }
    }

    /// Reads Terminal's tabs again soon (a tab moved into a window the watermark doesn't know).
    func requestTerminalWindows() {
        loader.requestTerminalWindows()
        refresh()
    }

    /// Expanded-list order: waiting, error, busy, then everything else; stable by start time.
    /// ⌃⌥1…9 follow it too.
    var listSessions: [IslandSession] { Self.listOrder(snapshot.sessions) }

    static func listOrder(_ sessions: [IslandSession]) -> [IslandSession] {
        sessions.sorted { a, b in
            if a.status.sortRank != b.status.sortRank { return a.status.sortRank < b.status.sortRank }
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.id < b.id
        }
    }

    /// Collapsed dots keep a fixed position per session (start order).
    var dotSessions: [IslandSession] {
        snapshot.sessions.sorted { a, b in
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.id < b.id
        }
    }

    var waitingCount: Int { snapshot.sessions.filter { $0.status == .waiting }.count }
    var busyCount: Int { snapshot.sessions.filter { $0.status == .busy }.count }

    func session(id: String?) -> IslandSession? {
        guard let id else { return nil }
        return snapshot.sessions.first { $0.id == id }
    }

    func theme(_ id: String?) -> ThemeInfo? {
        guard let id else { return nil }
        return snapshot.themes.first { $0.id == id }
    }

    /// Accents offered in a session's Color menu: its own theme, else the global/default theme.
    func accents(for session: IslandSession) -> [Accent] {
        for id in [session.theme, snapshot.globalThemeId, snapshot.defaultThemeId] {
            if let theme = theme(id), !theme.accents.isEmpty { return theme.accents }
        }
        if let first = snapshot.themes.first(where: { !$0.accents.isEmpty }) { return first.accents }
        return Palette.fallbackAccents
    }
}

// MARK: - Loader (background queue only)

/// Joins Claude Code's live registry (~/.claude/sessions/<pid>.json) with tabby's
/// per-session records (~/.claude/tabby/sessions/<id>.json). Only ever used from the
/// store's serial queue, hence the unchecked Sendable.
final class SnapshotLoader: @unchecked Sendable {
    private struct TranscriptInfo {
        var mtime: Date
        var size: UInt64
        var readAt = Date()
        var tokens: Int?
        var apiModel: String?
        var modelId: String?
        var marketingName: String?
        var lastPrompt: String?
        var tasks: TaskProgress?
        /// The step under way ("Editing tile.js"), and the gist of the reply that ended the last turn.
        var activity: String?
        var reply: ReplySummary?
    }

    /// A transcript's finished turns, read once from up to 16 MB back, then only as it grows.
    private struct TurnScan {
        var offset: UInt64
        var clock = TranscriptTurns.Clock()
    }

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var transcripts: [String: TranscriptInfo] = [:]
    private var turnScans: [String: TurnScan] = [:]
    private let turnScanBytes: UInt64 = 16 * 1024 * 1024
    private var heads: [String: (modelId: String?, marketing: String?)] = [:]
    private var processes: [Int: (tty: String?, term: String?)] = [:]
    private var themeCache: (stamp: FileStamp, themes: ThemeLoad)?
    /// When a Terminal tab's window first went unknown; it's asked for urgently only for a while.
    private var missingWindowSince: [String: Date] = [:]
    private let tailBytes: UInt64 = 256 * 1024
    private let headBytes = 128 * 1024
    private let titleReader: TerminalTitleReader
    private let subagents = SubagentScanner()

    init(automation: Bool) {
        titleReader = TerminalTitleReader(enabled: automation)
    }

    /// The watermark saw a Terminal window no known tab lives in: read Terminal's tabs again soon.
    func requestTerminalWindows() {
        titleReader.requestUrgent()
    }

    private var claudeDir: URL { ClaudePaths.dir }
    private var tabbyDir: URL { ClaudePaths.tabby }

    func load() -> StoreSnapshot {
        var snapshot = StoreSnapshot()
        snapshot.loaded = true
        snapshot.cli = loadCLI()
        let themes = loadThemes()
        snapshot.themes = themes.list
        snapshot.groups = themes.groups
        snapshot.defaultThemeId = themes.defaultId
        let config = readJSON(tabbyDir.appendingPathComponent("config.json"))
        snapshot.globalThemeId = str(config?["theme"]) ?? themes.defaultId
        snapshot.configRaw = (config ?? [:]).mapValues { ConfigValue($0) }
        snapshot.config = IslandConfig(raw: snapshot.configRaw)
        // The watermark and focus mode draw over each session's Terminal window.
        let windows = snapshot.config.watermark.enabled || snapshot.config.focusMode
        snapshot.sessions = loadSessions(windows: windows, focus: snapshot.config.focusMode)
        snapshot.automationDenied = titleReader.automationDenied
        if windows { snapshot.terminalWindowIds = Set(titleReader.terminalWindows().values) }
        snapshot.tiling = TileProgress.read()
        return snapshot
    }

    // MARK: Sessions

    /// `windows`: also find each Terminal.app session's window (for the watermark and focus
    /// mode). `focus`: also find the subagents of working sessions (focus mode's cover lists them).
    private func loadSessions(windows: Bool, focus: Bool = false) -> [IslandSession] {
        var recordsById: [String: [String: Any]] = [:]
        var recordsByPid: [Int: [String: Any]] = [:]
        let recordDir = tabbyDir.appendingPathComponent("sessions", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: recordDir.path)) ?? [] where name.hasSuffix(".json") {
            guard let record = readJSON(recordDir.appendingPathComponent(name)) else { continue }
            let sessionId = str(record["sessionId"]) ?? String(name.dropLast(5))
            recordsById[sessionId] = record
            if let pid = int(record["pid"]) {
                let newer = (num(record["updatedAt"]) ?? 0) >= (num(recordsByPid[pid]?["updatedAt"]) ?? 0)
                if recordsByPid[pid] == nil || newer { recordsByPid[pid] = record }
            }
        }

        // Turn lengths from every session tabby has seen: a new session's estimates start from these.
        let allTurns = recordsById.values.flatMap { ($0["turns"] as? [Any])?.compactMap { num($0) } ?? [] }
        let everyonesTypical = ProgressGuess.typical(Array(allTurns.suffix(200)), minimum: 5)

        let registryDir = claudeDir.appendingPathComponent("sessions", isDirectory: true)
        let registryNames = try? fm.contentsOfDirectory(atPath: registryDir.path)
        let terminalTitles = titleReader.current()
        let terminalWindows = windows ? titleReader.terminalWindows() : [:]
        var needs = TitleNeeds(windows: windows)
        var sessions: [IslandSession] = []
        var seenPids = Set<Int>()
        var usedTranscripts = Set<String>()

        for name in registryNames ?? [] where name.hasSuffix(".json") {
            guard let entry = readJSON(registryDir.appendingPathComponent(name)) else { continue }
            if let kind = str(entry["kind"]), kind != "interactive" { continue }
            guard let pid = int(entry["pid"]) ?? Int(name.dropLast(5)),
                  !seenPids.contains(pid), isAlive(pid) else { continue }
            seenPids.insert(pid)
            let sessionId = str(entry["sessionId"])
            let startedAt = num(entry["startedAt"]) ?? 0
            var record = sessionId.flatMap { recordsById[$0] }
            // After /clear the session id changes; fall back to this process's newest record,
            // but never to one written before this process started (pid reuse).
            if record == nil, let candidate = recordsByPid[pid],
               (num(candidate["updatedAt"]) ?? 0) >= startedAt - 5_000 {
                record = candidate
            }
            sessions.append(makeSession(entry: entry, record: record, pid: pid, sessionId: sessionId,
                                        terminalTitles: terminalTitles, terminalWindows: terminalWindows,
                                        typical: everyonesTypical, focus: focus, needs: &needs, usedTranscripts: &usedTranscripts))
        }

        // Claude Code builds without the registry: trust live tabby records instead.
        if registryNames == nil {
            for (sessionId, record) in recordsById {
                guard let pid = int(record["pid"]), !seenPids.contains(pid), isAlive(pid),
                      SessionStatus(raw: str(record["status"])) != .ended else { continue }
                seenPids.insert(pid)
                sessions.append(makeSession(entry: nil, record: record, pid: pid, sessionId: sessionId,
                                            terminalTitles: terminalTitles, terminalWindows: terminalWindows,
                                            typical: everyonesTypical, focus: focus, needs: &needs, usedTranscripts: &usedTranscripts))
            }
        }

        // A tab whose window isn't known is asked for right away, but only for its first 15 s:
        // a tty Terminal doesn't list (screen, say) must not trigger a read every second.
        let now = Date()
        missingWindowSince = missingWindowSince.filter { needs.missing.contains($0.key) }
        for tty in needs.missing where missingWindowSince[tty] == nil { missingWindowSince[tty] = now }
        let urgent = missingWindowSince.values.contains { now.timeIntervalSince($0) < 15 }
        // Titles are read every 3 s; windows alone (the watermark) every 6 s.
        titleReader.refreshIfNeeded(terminal: needs.terminalTitles || needs.terminalWindows, iTerm: needs.iTerm,
                                    every: needs.terminalTitles || needs.iTerm ? 3 : 6, urgent: urgent)
        transcripts = transcripts.filter { usedTranscripts.contains($0.key) }
        turnScans = turnScans.filter { usedTranscripts.contains($0.key) }
        heads = heads.filter { usedTranscripts.contains($0.key) }
        processes = processes.filter { seenPids.contains($0.key) }
        return sessions
    }

    private struct TitleNeeds {
        /// Look up Terminal.app windows too (the watermark is on).
        var windows = false
        /// Sessions without a tabby title, in Terminal.app and iTerm2.
        var terminalTitles = false
        var iTerm = false
        /// A Terminal.app session whose window to find.
        var terminalWindows = false
        /// Terminal ttys without a known window.
        var missing: Set<String> = []
    }

    private func makeSession(entry: [String: Any]?, record: [String: Any]?, pid: Int, sessionId: String?,
                             terminalTitles: [String: String], terminalWindows: [String: Int],
                             typical everyones: TimeInterval?, focus: Bool, needs: inout TitleNeeds,
                             usedTranscripts: inout Set<String>) -> IslandSession {
        let cwd = str(record?["cwd"]) ?? str(entry?["cwd"]) ?? ""
        let project = str(record?["project"]) ?? (cwd.isEmpty ? "session" : URL(fileURLWithPath: cwd).lastPathComponent)

        let recordStatus = SessionStatus(raw: str(record?["status"]))
        let status: SessionStatus
        if recordStatus == .error {
            status = .error
        } else if let live = str(entry?["status"]) {
            status = SessionStatus(raw: live)
        } else {
            status = recordStatus
        }

        var context: ContextUsage?
        if let c = record?["context"] as? [String: Any] {
            context = ContextUsage(usedPct: num(c["usedPct"]), usedTokens: int(c["usedTokens"]),
                                   windowSize: int(c["windowSize"]), costUsd: num(c["costUsd"]),
                                   model: str(c["model"]), at: num(c["at"]))
        }
        let prompts = (record?["prompts"] as? [Any])?.compactMap { $0 as? String } ?? []
        var lastPrompt = prompts.last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var model = context?.model

        let nowMs = Date().timeIntervalSince1970 * 1000
        let hasUsage = context?.usedPct != nil || context?.usedTokens != nil
        let stale = context?.at.map { nowMs - $0 > 60_000 } ?? true
        var tasks: TaskProgress?
        var activity: String?
        var reply: ReplySummary?
        var transcriptTurns: [Double] = []
        // A working session's transcript is read for Claude's task list and the step it's on too
        // (at most every 3 s); with focus mode, a finished one's for the gist of its reply.
        if !hasUsage || stale || lastPrompt == nil || model == nil || status == .busy || (focus && status == .idle),
           let path = transcriptPath(record: record, cwd: cwd, sessionId: sessionId) {
            usedTranscripts.insert(path)
            if let info = transcriptInfo(path) {
                if status == .idle { reply = info.reply }
                if status == .busy {
                    tasks = info.tasks
                    activity = info.activity
                    // Until tabby's hooks have timed a few of this session's turns.
                    if ((record?["turns"] as? [Any])?.count ?? 0) < 3 { transcriptTurns = pastTurns(path, size: info.size) }
                }
                if !hasUsage || stale, let tokens = info.tokens {
                    let oneMillion = (info.modelId?.contains("[1m]") ?? false) || tokens > 200_000
                    let window = oneMillion ? 1_000_000 : 200_000
                    context = ContextUsage(usedPct: Double(tokens) / Double(window) * 100, usedTokens: tokens,
                                           windowSize: window, costUsd: context?.costUsd, model: context?.model,
                                           at: info.mtime.timeIntervalSince1970 * 1000)
                }
                if lastPrompt == nil { lastPrompt = info.lastPrompt }
                if model == nil { model = info.marketingName ?? info.modelId ?? info.apiModel }
            }
        }

        var tty = str(record?["tty"]).flatMap(Self.devicePath)
        var term = str(record?["term"])
        if tty == nil || term == nil {
            let probe = processInfo(pid)
            tty = tty ?? probe.tty
            term = term ?? probe.term
        }

        // Title priority: tabby's title → the terminal's live tab title (Claude's AI topic
        // title lives there) → Claude's registry name → the project folder.
        let registryName = str(entry?["name"])
        let recordTitle = str(record?["title"])
        var terminalTitle: String?
        if recordTitle == nil {
            if (term ?? "").contains("iterm") { needs.iTerm = true } else { needs.terminalTitles = true }
            terminalTitle = tty.flatMap { terminalTitles[$0] }
        }
        var windowId: Int?
        if needs.windows, (term ?? "apple-terminal") == "apple-terminal", let tty {
            needs.terminalWindows = true
            windowId = terminalWindows[tty]
            if windowId == nil { needs.missing.insert(tty) }
        }
        var agents: [FocusAgent] = []
        if focus, status == .busy, windowId != nil, let path = transcriptPath(record: record, cwd: cwd, sessionId: sessionId) {
            agents = subagents.running(transcript: path)
        }
        return IslandSession(
            id: sessionId ?? str(record?["sessionId"]) ?? "pid-\(pid)",
            sessionId: sessionId ?? str(record?["sessionId"]),
            pid: pid,
            cwd: cwd,
            project: project,
            registryName: registryName,
            title: recordTitle ?? terminalTitle ?? registryName ?? project,
            titleSource: str(record?["titleSource"]),
            summary: str(record?["summary"]),
            note: str(record?["note"]),
            theme: str(record?["theme"]),
            accentKey: str(record?["accentKey"]),
            accentHex: str(record?["accent"]),
            dotHex: str(record?["dot"]) ?? ColorMath.onBlack(str(record?["accent"])),
            cursorHex: str(record?["cursor"]),
            status: status,
            waitingFor: str(entry?["waitingFor"]) ?? str(record?["waitingFor"]),
            lastPrompt: lastPrompt.map { Fmt.oneLine($0, max: 240) },
            context: context,
            model: model.map(Fmt.prettyModel),
            tty: tty,
            term: term,
            startedAt: num(entry?["startedAt"]) ?? num(record?["startedAt"]) ?? 0,
            activityAt: num(entry?["statusUpdatedAt"]) ?? num(entry?["updatedAt"])
                ?? num(record?["statusAt"]) ?? num(record?["updatedAt"]),
            hasRecord: record != nil,
            windowId: windowId,
            disabled: bool(record?["disabled"]) ?? false,
            turnStartedAt: num(record?["turnStartedAt"]),
            turnWaitMs: num(record?["turnWaitMs"]) ?? 0,
            waitingSince: num(record?["waitingSince"]),
            // Timed by tabby's hooks, else read from the transcript, else every session's.
            typicalTurn: ProgressGuess.typical((record?["turns"] as? [Any])?.compactMap { num($0) } ?? [])
                ?? ProgressGuess.typical(transcriptTurns) ?? everyones,
            lastTurnMs: num(record?["lastTurnMs"]),
            tasks: tasks,
            activity: activity,
            reply: reply,
            bgHex: str(record?["bg"]),
            fgHex: str(record?["fg"]),
            agents: agents
        )
    }

    private func processInfo(_ pid: Int) -> (tty: String?, term: String?) {
        if let cached = processes[pid] { return cached }
        let info = (tty: ProcessProbe.tty(pid: pid),
                    term: ProcessProbe.environment(pid: pid, key: "TERM_PROGRAM").map(ProcessProbe.normalizeTerm))
        processes[pid] = info
        return info
    }

    // MARK: Transcript fallback (context usage, model, last prompt)

    private func transcriptPath(record: [String: Any]?, cwd: String, sessionId: String?) -> String? {
        if let path = str(record?["transcriptPath"]), isTranscript(path) { return path }
        guard let sessionId, !cwd.isEmpty else { return nil }
        let projects = claudeDir.appendingPathComponent("projects", isDirectory: true)
        let alnum = String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        let slashes = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        for dir in [alnum, slashes] {
            let path = projects.appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent("\(sessionId).jsonl").path
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// A transcript is a regular file inside Claude's projects folder: a record can't point the
    /// island at a device, a pipe (reading one never returns) or a file somewhere else.
    private func isTranscript(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let projects = claudeDir.appendingPathComponent("projects", isDirectory: true).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(projects + "/") else { return false }
        return (try? fm.attributesOfItem(atPath: resolved))?[.type] as? FileAttributeType == .typeRegular
    }

    private func transcriptInfo(_ path: String) -> TranscriptInfo? {
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let mtime = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        // Busy sessions append to their transcript constantly; re-parse at most every 3 s.
        if let cached = transcripts[path],
           (cached.mtime == mtime && cached.size == size) || Date().timeIntervalSince(cached.readAt) < 3 {
            return cached
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        let tail = (try? handle.readToEnd()) ?? Data()
        var info = TranscriptInfo(mtime: mtime, size: size)
        parseTail(tail, startsMidFile: start > 0, into: &info)

        // The model attachment ("modelId": "claude-…[1m]") is usually near the top of
        // long transcripts; the head never changes, so scan it once per file.
        if info.modelId == nil, start > 0 {
            if heads[path] == nil {
                try? handle.seek(toOffset: 0)
                let head = (try? handle.read(upToCount: headBytes)) ?? Data()
                heads[path] = scanModelIds(String(decoding: head, as: UTF8.self))
            }
            info.modelId = heads[path]?.modelId
            if info.marketingName == nil { info.marketingName = heads[path]?.marketing }
        }
        transcripts[path] = info
        return info
    }

    private func parseTail(_ data: Data, startsMidFile: Bool, into info: inout TranscriptInfo) {
        let text = String(decoding: data, as: UTF8.self)
        let ids = scanModelIds(text)
        info.modelId = ids.modelId
        info.marketingName = ids.marketing

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if startsMidFile, !lines.isEmpty { lines.removeFirst() }
        info.tasks = TaskParser.parse(lines)
        info.activity = TranscriptActivity.current(lines)
        info.reply = TranscriptActivity.lastReply(lines)
        for line in lines.reversed() {
            if info.tokens != nil && info.lastPrompt != nil { break }
            if line.contains("\"isSidechain\":true") { continue }
            if info.tokens == nil, line.contains("\"type\":\"assistant\""), line.contains("\"usage\"") {
                guard let object = parseLine(line), str(object["type"]) == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                let tokens = (int(usage["input_tokens"]) ?? 0)
                    + (int(usage["cache_creation_input_tokens"]) ?? 0)
                    + (int(usage["cache_read_input_tokens"]) ?? 0)
                if tokens > 0 {
                    info.tokens = tokens
                    info.apiModel = str(message["model"])
                }
            } else if info.lastPrompt == nil, line.contains("\"type\":\"user\""),
                      !line.contains("\"tool_result\""), !line.contains("\"isMeta\":true") {
                guard let object = parseLine(line), str(object["type"]) == "user",
                      let message = object["message"] as? [String: Any] else { continue }
                info.lastPrompt = userText(message["content"])
            }
        }
    }

    /// This session's finished turn lengths (ms), from its transcript. The first call reads up to
    /// 16 MB back; later ones read only what was written since.
    private func pastTurns(_ path: String, size: UInt64) -> [Double] {
        var scan = turnScans[path] ?? TurnScan(offset: size > turnScanBytes ? size - turnScanBytes : 0)
        let midFile = turnScans[path] == nil && scan.offset > 0
        if size < scan.offset { scan = TurnScan(offset: 0) }   // rewritten
        guard size > scan.offset, let handle = FileHandle(forReadingAtPath: path) else {
            turnScans[path] = scan
            return scan.clock.durations
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: scan.offset)
        let data = (try? handle.read(upToCount: Int(min(size - scan.offset, turnScanBytes)))) ?? Data()
        // Only whole lines: the rest is read next time.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            turnScans[path] = scan
            return scan.clock.durations
        }
        let text = String(decoding: data[..<lastNewline], as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if midFile, !lines.isEmpty { lines.removeFirst() }
        for line in lines {
            scan.clock.feed(line, isPrompt: isPromptLine(line))
        }
        scan.offset += UInt64(lastNewline - data.startIndex + 1)
        turnScans[path] = scan
        return scan.clock.durations
    }

    /// A line where you typed a prompt (not a tool result, a command or a note from Claude Code).
    private func isPromptLine(_ line: Substring) -> Bool {
        guard line.contains("\"type\":\"user\""), !line.contains("\"tool_result\""), !line.contains("\"isMeta\":true"),
              let object = parseLine(line), str(object["type"]) == "user",
              let message = object["message"] as? [String: Any] else { return false }
        return userText(message["content"]) != nil
    }

    /// Latest `"modelId":"…"` and `"marketingName":"…"` values in a chunk of JSONL.
    private func scanModelIds(_ text: String) -> (modelId: String?, marketing: String?) {
        func lastValue(of key: String) -> String? {
            let needle = "\"\(key)\":\""
            var result: String?
            var rest = text[...]
            while let found = rest.range(of: needle) {
                let after = rest[found.upperBound...]
                guard let end = after.firstIndex(of: "\"") else { break }
                result = String(after[..<end])
                rest = after[end...]
            }
            return result
        }
        var marketing = lastValue(of: "marketingName")
        if let name = marketing, let paren = name.range(of: " (") { marketing = String(name[..<paren.lowerBound]) }
        return (lastValue(of: "modelId"), marketing)
    }

    private func userText(_ content: Any?) -> String? {
        var text: String?
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [Any] {
            let parts = blocks.compactMap { block -> String? in
                guard let block = block as? [String: Any], str(block["type"]) == "text" else { return nil }
                return str(block["text"])
            }
            if !parts.isEmpty { text = parts.joined(separator: " ") }
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.hasPrefix("<"), !trimmed.hasPrefix("[Request interrupted") else { return nil }
        return trimmed
    }

    private func parseLine(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    // MARK: Themes, config, CLI location

    struct ThemeLoad {
        var list: [ThemeInfo] = []
        var groups: [ThemeGroup] = []
        var defaultId: String?
    }

    struct FileStamp: Equatable {
        var mtime: Date
        var size: UInt64
    }

    /// themes.json is ~60 KB and rarely changes: parse it again only when it does.
    private func loadThemes() -> ThemeLoad {
        let url = tabbyDir.appendingPathComponent("themes.json")
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            themeCache = nil
            return ThemeLoad()
        }
        let stamp = FileStamp(mtime: mtime, size: size)
        if let cache = themeCache, cache.stamp == stamp { return cache.themes }
        let themes = parseThemes(readJSON(url))
        themeCache = (stamp, themes)
        return themes
    }

    /// Menu sections in tabby's order; unknown groups follow in order of first use.
    private static let groupOrder = ["signature", "calm", "classic", "vivid", "light", "contrast"]
    private static let groupNames = ["signature": "Signature", "calm": "Calm", "classic": "Classic",
                                     "vivid": "Vivid", "light": "Light", "contrast": "High contrast"]

    private func parseThemes(_ json: [String: Any]?) -> ThemeLoad {
        guard let json else { return ThemeLoad() }
        let keyOrder = (json["accentKeys"] as? [Any])?.compactMap { $0 as? String } ?? []
        var themes: [ThemeInfo] = []
        for case let theme as [String: Any] in (json["themes"] as? [Any]) ?? [] {
            guard let id = str(theme["id"]) else { continue }
            let dots = theme["dots"] as? [String: Any]
            var accents: [Accent] = []
            func add(_ key: String, _ hex: String) {
                accents.append(Accent(key: key, hex: hex, dot: str(dots?[key]) ?? ColorMath.onBlack(hex) ?? hex))
            }
            if let map = theme["accents"] as? [String: Any] {
                for (key, value) in map { if let hex = str(value) { add(key, hex) } }
            } else if let list = theme["accents"] as? [Any] {
                for case let item as [String: Any] in list {
                    if let key = str(item["key"]), let hex = str(item["hex"]) { add(key, hex) }
                }
            }
            // tabby's accent order (red … pink) when known, else rainbow order.
            accents.sort { a, b in
                let i = keyOrder.firstIndex(of: a.key) ?? Int.max, j = keyOrder.firstIndex(of: b.key) ?? Int.max
                return i != j ? i < j : Hue.ordered(a, b)
            }
            let mode = str(theme["mode"]) ?? "dark"
            // Older themes.json files have no groups: light themes, calm darks, the rest.
            let group = str(theme["group"]) ?? (mode == "light" ? "light" : (bool(theme["calm"]) == true ? "calm" : "classic"))
            themes.append(ThemeInfo(id: id, name: str(theme["name"]) ?? id, mode: mode, group: group,
                                    bg: str(theme["bg"]) ?? "#1e1e1e", fg: str(theme["fg"]) ?? "#d0d0d0",
                                    accents: accents, blurb: str(theme["blurb"]) ?? ""))
        }
        let names = json["groups"] as? [String: Any] ?? [:]
        var order = Self.groupOrder.filter { id in themes.contains { $0.group == id } }
        for theme in themes where !order.contains(theme.group) { order.append(theme.group) }
        let groups = order.map { id in
            ThemeGroup(id: id, name: str(names[id]) ?? Self.groupNames[id] ?? id.capitalized)
        }
        return ThemeLoad(list: themes, groups: groups, defaultId: str(json["default"]))
    }

    private func loadCLI() -> CLIConfig {
        // The sh launcher finds a Node wherever it lives (even one installed after the island).
        let launcher = tabbyDir.appendingPathComponent("bin/tabby").path
        if fm.fileExists(atPath: launcher) { return CLIConfig(node: "/bin/sh", cli: launcher) }
        let json = readJSON(tabbyDir.appendingPathComponent("island.json"))
        var node = str(json?["node"])
        if node == nil || !fm.isExecutableFile(atPath: node!) {
            node = [tabbyDir.appendingPathComponent("node/bin/node").path, "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
                .first { fm.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/node"
        }
        var cli = str(json?["cli"])
        if cli == nil || !fm.fileExists(atPath: cli!) {
            // <repo>/island/build/Tabby Island.app → <repo>/bin/tabby.js
            let repo = Bundle.main.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let bundled = repo.appendingPathComponent("bin/tabby.js").path
            // None: the island says tabby's CLI wasn't found, and runs nothing.
            cli = fm.fileExists(atPath: bundled) ? bundled : ""
        }
        return CLIConfig(node: node!, cli: cli!)
    }

    /// A tty as a record names it, only if it's a device path ("/dev/ttys003"): it's handed to
    /// osascript as an argument, where anything else could be read as an option.
    static func devicePath(_ tty: String) -> String? {
        guard tty.hasPrefix("/dev/"), tty.count < 64,
              tty.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "/._-".unicodeScalars.contains($0)) })
        else { return nil }
        return tty
    }

    // MARK: Helpers

    /// Regular files only (a pipe or a device with a .json name would never finish reading),
    /// and none larger than a state file could be.
    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let attributes = try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value, size > 0, size <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func isAlive(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}

/// A number from a JSON file, if it's one a session could have (finite, and far inside what an
/// Int holds): everything downstream converts and formats it without checking again.
private func num(_ value: Any?) -> Double? {
    let double: Double?
    switch value {
    case let number as NSNumber: double = number.doubleValue
    case let string as String: double = Double(string)
    default: double = nil
    }
    guard let double, double.isFinite, abs(double) < 1e15 else { return nil }
    return double
}

private func int(_ value: Any?) -> Int? {
    num(value).flatMap { Int(exactly: $0.rounded(.towardZero)) }
}

private func str(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
}

/// JSON booleans, 0/1, or "true"/"false"/"on"/"off" strings (config values set by hand).
private func bool(_ value: Any?) -> Bool? {
    switch value {
    case let number as NSNumber: return number.boolValue
    case let string as String:
        switch string.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    default: return nil
    }
}

// MARK: - Process probing (tty + terminal of sessions tabby hasn't recorded)

enum ProcessProbe {
    /// Controlling terminal of a process, e.g. "/dev/ttys003".
    static func tty(pid: Int) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.isEmpty || tty == "??" ? nil : "/dev/\(tty)"
    }

    /// Reads one environment variable of a same-user process via KERN_PROCARGS2.
    static func environment(pid: Int, key: String) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 8 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }          // executable path
        while i < size && buffer[i] == 0 { i += 1 }          // padding
        var seen: Int32 = 0
        while i < size && seen < argc {                        // argv
            while i < size && buffer[i] != 0 { i += 1 }
            i += 1
            seen += 1
        }
        let prefix = Array("\(key)=".utf8)
        while i < size {                                       // envp
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            if i == start { break }
            let entry = buffer[start..<i]
            if entry.starts(with: prefix) {
                return String(decoding: entry.dropFirst(prefix.count), as: UTF8.self)
            }
            i += 1
        }
        return nil
    }

    static func normalizeTerm(_ termProgram: String) -> String {
        switch termProgram.lowercased() {
        case "apple_terminal": return "apple-terminal"
        case "iterm.app": return "iterm2"
        default: return termProgram.lowercased()
        }
    }
}
