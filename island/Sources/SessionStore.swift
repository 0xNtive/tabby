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
    var cli = CLIConfig(node: "/opt/homebrew/bin/node", cli: "")
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

    var globalThemeName: String? { theme(snapshot.globalThemeId)?.name }

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
    }

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var transcripts: [String: TranscriptInfo] = [:]
    private var heads: [String: (modelId: String?, marketing: String?)] = [:]
    private var processes: [Int: (tty: String?, term: String?)] = [:]
    private var themeCache: (stamp: FileStamp, themes: ThemeLoad)?
    private let tailBytes: UInt64 = 256 * 1024
    private let headBytes = 128 * 1024
    private let titleReader: TerminalTitleReader

    init(automation: Bool) {
        titleReader = TerminalTitleReader(enabled: automation)
    }

    private var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    private var tabbyDir: URL { claudeDir.appendingPathComponent("tabby", isDirectory: true) }

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
        snapshot.config = IslandConfig(
            mode: IslandMode(raw: str(config?["islandMode"])) ?? .standard,
            announce: bool(config?["islandAnnounce"]) ?? true,
            hotkeys: bool(config?["islandHotkeys"]) ?? true
        )
        snapshot.sessions = loadSessions()
        return snapshot
    }

    // MARK: Sessions

    private func loadSessions() -> [IslandSession] {
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

        let registryDir = claudeDir.appendingPathComponent("sessions", isDirectory: true)
        let registryNames = try? fm.contentsOfDirectory(atPath: registryDir.path)
        let terminalTitles = titleReader.current()
        var needs = TitleNeeds()
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
                                        terminalTitles: terminalTitles, needs: &needs,
                                        usedTranscripts: &usedTranscripts))
        }

        // Claude Code builds without the registry: trust live tabby records instead.
        if registryNames == nil {
            for (sessionId, record) in recordsById {
                guard let pid = int(record["pid"]), !seenPids.contains(pid), isAlive(pid),
                      SessionStatus(raw: str(record["status"])) != .ended else { continue }
                seenPids.insert(pid)
                sessions.append(makeSession(entry: nil, record: record, pid: pid, sessionId: sessionId,
                                            terminalTitles: terminalTitles, needs: &needs,
                                            usedTranscripts: &usedTranscripts))
            }
        }

        titleReader.refreshIfNeeded(terminal: needs.terminal, iTerm: needs.iTerm)
        transcripts = transcripts.filter { usedTranscripts.contains($0.key) }
        heads = heads.filter { usedTranscripts.contains($0.key) }
        processes = processes.filter { seenPids.contains($0.key) }
        return sessions
    }

    private struct TitleNeeds {
        var terminal = false
        var iTerm = false
    }

    private func makeSession(entry: [String: Any]?, record: [String: Any]?, pid: Int, sessionId: String?,
                             terminalTitles: [String: String], needs: inout TitleNeeds,
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
        if !hasUsage || stale || lastPrompt == nil || model == nil,
           let path = transcriptPath(record: record, cwd: cwd, sessionId: sessionId) {
            usedTranscripts.insert(path)
            if let info = transcriptInfo(path) {
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

        var tty = str(record?["tty"])
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
            if (term ?? "").contains("iterm") { needs.iTerm = true } else { needs.terminal = true }
            terminalTitle = tty.flatMap { terminalTitles[$0] }
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
            hasRecord: record != nil
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
        if let path = str(record?["transcriptPath"]), fm.fileExists(atPath: path) { return path }
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

    private func transcriptInfo(_ path: String) -> TranscriptInfo? {
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let mtime = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        // Busy sessions append to their transcript constantly; re-parse at most every 5 s.
        if let cached = transcripts[path],
           (cached.mtime == mtime && cached.size == size) || Date().timeIntervalSince(cached.readAt) < 5 {
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
        let json = readJSON(tabbyDir.appendingPathComponent("island.json"))
        var node = str(json?["node"])
        if node == nil || !fm.isExecutableFile(atPath: node!) {
            node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
                .first { fm.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/node"
        }
        var cli = str(json?["cli"])
        if cli == nil || !fm.fileExists(atPath: cli!) {
            // <repo>/island/build/Tabby Island.app → <repo>/bin/tabby.js
            let repo = Bundle.main.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let bundled = repo.appendingPathComponent("bin/tabby.js").path
            cli = fm.fileExists(atPath: bundled)
                ? bundled
                : home.appendingPathComponent("Dev/tabby/bin/tabby.js").path
        }
        return CLIConfig(node: node!, cli: cli!)
    }

    // MARK: Helpers

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func isAlive(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}

private func num(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber: return number.doubleValue
    case let string as String: return Double(string)
    default: return nil
    }
}

private func int(_ value: Any?) -> Int? {
    guard let double = num(value), double.isFinite else { return nil }
    return Int(double)
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
