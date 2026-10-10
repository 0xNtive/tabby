// Checks for the island's model code: shortcuts, config values, watermark settings and layout.
// Run with: bash island/test.sh
import AppKit
import Carbon.HIToolbox

/// The real one lives in Debug.swift, which needs the whole app.
enum Debug { static func log(_ message: @autoclosure () -> String) {} }

var failures = 0
func check(_ ok: Bool, _ label: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(label)") }
}

// Key combos
let w = KeyCombo(spec: "ctrl+opt+w")
check(w == KeyCombo(kVK_ANSI_W, [.control, .option]), "ctrl+opt+w parses")
check(w?.display == "⌃⌥W", "display ⌃⌥W, got \(w?.display ?? "nil")")
check(w?.spec == "ctrl+opt+w", "spec round trip")
check(KeyCombo(spec: "cmd+shift+f5")?.display == "⇧⌘F5", "⇧⌘F5")
check(KeyCombo(spec: "Control+Option+Space")?.display == "⌃⌥Space", "space, case-insensitive")
check(KeyCombo(spec: "ctrl+opt+,")?.display == "⌃⌥,", "comma")
check(KeyCombo(spec: "ctrl+opt+comma")?.keyCode == kVK_ANSI_Comma, "comma alias")
check(KeyCombo(spec: "ctrl+opt+") == nil, "dangling plus")
check(KeyCombo(spec: "hyper+w") == nil, "unknown modifier")
check(KeyCombo(spec: "") == nil, "empty")
check(KeyCombo(spec: "opt+left")?.display == "⌥←", "arrow")
check(KeyCombo(spec: "ctrl+opt+w")?.menuKey == "w", "menu key")
check(KeyCombo(spec: "ctrl+opt+space")?.menuKey == " ", "menu key space")
for action in ShortcutAction.allCases {
    let combo = action.defaultCombo
    check(KeyCombo(spec: combo.spec) == combo, "default \(action) round-trips via \(combo.spec)")
}

// Config
let raw: [String: ConfigValue] = ["islandShortcuts": .object(["watermark": .string("cmd+shift+w"), "settings": .string(""), "jump": .string("ctrl+cmd"), "tile": .string("garbage+x")])]
let config = IslandConfig(raw: raw)
check(config.shortcuts[.watermark] == KeyCombo(kVK_ANSI_W, [.command, .shift]), "override")
check(config.shortcuts[.settings] == nil, "'' turns it off")
check(config.shortcuts[.jump] == KeyCombo(kVK_ANSI_1, [.control, .command]), "jump from modifiers alone")
check(config.shortcuts[.tile] == ShortcutAction.tile.defaultCombo, "unreadable keeps default")
check(config.shortcuts[.next] == ShortcutAction.next.defaultCombo, "untouched default")
let overrides = config.shortcuts.overrides
check(overrides["watermark"] == .string("shift+cmd+w") && overrides["settings"] == .string("") && overrides["jump"] == .string("ctrl+cmd+1") && overrides["tile"] == nil && overrides.count == 3, "overrides: \(overrides)")
check(IslandConfig(raw: ["islandShortcuts": .object(overrides)]).shortcuts == config.shortcuts, "overrides round trip")
check(ShortcutAction.defaults.overrides.isEmpty, "defaults write nothing")

// Collisions
let hyper: KeyModifiers = [.control, .option]
check(!ShortcutAction.jump.collides(KeyCombo(kVK_ANSI_1, hyper), with: KeyCombo(kVK_ANSI_N, hyper), of: .next), "jump vs ⌃⌥N")
check(ShortcutAction.jump.collides(KeyCombo(kVK_ANSI_1, hyper), with: KeyCombo(kVK_ANSI_5, hyper), of: .next), "jump vs ⌃⌥5")
check(ShortcutAction.tile.collides(KeyCombo(kVK_ANSI_7, hyper), with: KeyCombo(kVK_ANSI_1, hyper), of: .jump), "⌃⌥7 vs jump")
check(!ShortcutAction.tile.collides(KeyCombo(kVK_ANSI_0, hyper), with: KeyCombo(kVK_ANSI_1, hyper), of: .jump), "⌃⌥0 is free")
check(ShortcutAction.tile.collides(KeyCombo(kVK_ANSI_W, hyper), with: KeyCombo(kVK_ANSI_W, hyper), of: .watermark), "same combo")

// ConfigValue from JSON
let json = try! JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":"on","d":{"e":[1,false]},"f":null,"g":0.18}"#.utf8)) as! [String: Any]
let values = json.mapValues { ConfigValue($0) }
check(values["a"] == .bool(true) && values["b"] == .number(1), "bool vs number")
check(values["c"]?.bool == true && values["b"]?.bool == true, "lenient bools")
check(values["d"] == .object(["e": .array([.number(1), .bool(false)])]), "nested")
check(values["f"] == .null, "null")
check(ConfigValue.object(["b": .number(18), "a": .string("x\"y")]).json == #"{"a":"x\"y","b":18}"#, "json: \(ConfigValue.object(["b": .number(18), "a": .string("x\"y")]).json)")
check(ConfigValue.bool(false).json == "false" && ConfigValue.string("minimal").json == "\"minimal\"", "fragments")

// Watermark settings
check(WatermarkSettings().opacity == 18 && WatermarkSettings().enabled, "defaults")
check(WatermarkSettings(raw: ["watermarkOpacity": .number(0.25)]).opacity == 25, "fraction")
check(WatermarkSettings(raw: ["watermarkOpacity": .string("12%")]).opacity == 12, "percent string")
check(WatermarkSettings(raw: ["watermarkOpacity": .number(100)]).opacity == 40, "clamped")
check(WatermarkSettings(raw: ["watermark": .string("off")]).enabled == false, "off")
check(WatermarkSettings(raw: ["watermarkSize": .string("LARGE"), "watermarkPosition": .string("top"), "watermarkColor": .string("neutral")]) == {
    var s = WatermarkSettings(); s.size = .large; s.position = .top; s.color = .neutral; return s }(), "enums")

// Layout
let settings = WatermarkSettings()
let big = WatermarkView.layout("Refactor the authentication middleware for session tokens", tint: .white, settings: settings,
                                in: CGRect(x: 0, y: 0, width: 760, height: 460), topInset: 44)
check(big != nil, "long title lays out")
if let big {
    check(big.rect.minY >= 44 && big.rect.maxY <= 460 && big.rect.minX >= 0 && big.rect.maxX <= 760, "inside the window: \(big.rect)")
}
check(WatermarkView.layout("Tiny", tint: .white, settings: settings, in: CGRect(x: 0, y: 0, width: 50, height: 40), topInset: 44) == nil, "too small: nothing")
check(WatermarkView.layout("   ", tint: .white, settings: settings, in: CGRect(x: 0, y: 0, width: 760, height: 460), topInset: 44) == nil, "blank: nothing")
let top = WatermarkView.layout("Top", tint: .white, settings: { var s = settings; s.position = .top; return s }(), in: CGRect(x: 0, y: 0, width: 760, height: 460), topInset: 44)!
let bottom = WatermarkView.layout("Top", tint: .white, settings: { var s = settings; s.position = .bottom; return s }(), in: CGRect(x: 0, y: 0, width: 760, height: 460), topInset: 44)!
check(top.rect.minY < bottom.rect.minY, "top above bottom")

// Claude's task list
func line(_ blocks: String) -> String {
    #"{"type":"assistant","timestamp":"2026-09-27T10:00:00.000Z","message":{"content":["# + blocks + #"]}}"#
}
let create = { (subject: String) in line(#"{"type":"tool_use","name":"TaskCreate","input":{"subject":""# + subject + #""}}"#) }
let update = { (id: String, status: String) in line(#"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":""# + id + #"","status":""# + status + #""}}"#) }
var transcript = [create("Write the parser"), create("Wire it up"), create("Test it"), update("1", "completed"), update("2", "in_progress")]
check(TaskParser.parse(transcript) == TaskProgress(total: 3, done: 1, active: 1, current: "Wire it up"), "task list: \(String(describing: TaskParser.parse(transcript)))")
transcript += [update("2", "completed"), update("3", "completed")]
check(TaskParser.parse(transcript)?.open == false, "all done")
transcript += [create("A new plan")]
check(TaskParser.parse(transcript) == TaskProgress(total: 1, done: 0, active: 0, current: nil), "a new plan starts a new list")
check(TaskParser.parse([update("7", "in_progress")])?.total == 1, "a task created before what was read")
let todo = line(#"{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"A","activeForm":"Doing A","status":"completed"},{"content":"B","activeForm":"Doing B","status":"in_progress"},{"content":"C","status":"pending"}]}}"#)
check(TaskParser.parse([todo]) == TaskProgress(total: 3, done: 1, active: 1, current: "Doing B"), "TodoWrite")
check(TaskParser.parse(["{\"type\":\"user\"}"]) == nil, "no list")

// The estimate
let fromTasks = ProgressGuess.make(elapsed: 480, typical: 360, tasks: TaskProgress(total: 5, done: 2, active: 1, current: nil))!
check(abs(fromTasks.fraction! - 0.5) < 0.001 && fromTasks.caption == "2 of 5 tasks · ~8m left", "tasks: \(fromTasks)")
let early = ProgressGuess.make(elapsed: 30, typical: 360, tasks: TaskProgress(total: 5, done: 0, active: 1, current: nil))!
check(early.caption == "0 of 5 tasks" && early.remaining == nil, "no ETA before a task is done: \(early)")
let fromTime = ProgressGuess.make(elapsed: 120, typical: 360, tasks: nil)!
check(fromTime.caption == "~4m left · usually 6m" && abs(fromTime.fraction! - 0.3) < 0.001, "time: \(fromTime)")
let late = ProgressGuess.make(elapsed: 720, typical: 360, tasks: nil)!
check(late.remaining == nil && late.fraction! > 0.9 && late.fraction! < 0.98 && late.caption == "Longer than usual (6m)", "late: \(late)")
check(ProgressGuess.make(elapsed: 120, typical: nil, tasks: nil) == nil, "nothing to go on")
check(ProgressGuess.typical([60_000, 120_000]) == nil, "too few turns")
check(ProgressGuess.typical([60_000, 600_000, 120_000]) == 120, "median")
check(Fmt.left(45) == "<1m left" && Fmt.left(150) == "~3m left" && Fmt.left(7_200) == "~2h left", "left")
check(Fmt.worked(59) == nil && Fmt.worked(150) == "2m" && Fmt.worked(3_900) == "1h 5m", "worked")

// Past turns from a transcript
let turnLines = [
    #"{"type":"user","timestamp":"2026-09-27T10:00:00.000Z","message":{"content":"go"}}"#,
    #"{"type":"assistant","timestamp":"2026-09-27T10:01:30.000Z"}"#,
    #"{"type":"assistant","timestamp":"2026-09-27T10:03:00.500Z"}"#,
    #"{"type":"user","timestamp":"2026-09-27T10:10:00.000Z","message":{"content":"again"}}"#,
    #"{"type":"assistant","timestamp":"2026-09-27T10:11:00Z"}"#,
    #"{"type":"user","timestamp":"2026-09-27T10:20:00.000Z","message":{"content":"still running"}}"#,
    #"{"type":"assistant","timestamp":"2026-09-27T10:25:00.000Z"}"#,
]
let turns = TranscriptTurns.durations(turnLines) { $0.contains("\"type\":\"user\"") }
check(turns == [180_500, 60_000], "turns: \(turns)")

// A working session's elapsed time leaves out waits
var working = IslandSession(id: "w", sessionId: "w", pid: 1, cwd: "", project: "p", registryName: nil, title: "t",
                            titleSource: nil, summary: nil, note: nil, theme: nil, accentKey: nil, accentHex: nil,
                            dotHex: nil, cursorHex: nil, status: .busy, waitingFor: nil, lastPrompt: nil, context: nil,
                            model: nil, tty: nil, term: nil, startedAt: 0, activityAt: nil, hasRecord: true)
let nowDate = Date()
working.turnStartedAt = nowDate.timeIntervalSince1970 * 1000 - 300_000
working.turnWaitMs = 60_000
check(abs((working.workElapsed(now: nowDate) ?? 0) - 240) < 0.5, "elapsed without waits")
working.typicalTurn = 480
check(working.progress(now: nowDate)?.caption == "~4m left · usually 8m", "session progress: \(String(describing: working.progress(now: nowDate)))")
working.status = .idle
check(working.progress(now: nowDate) == nil, "no estimate on your turn")

// Focus mode: covered while Claude works, open when it needs you or you're in the window
check(FocusRule.covers(status: .busy, windowIsFront: false, terminalActive: true), "busy background window: covered")
check(FocusRule.covers(status: .busy, windowIsFront: true, terminalActive: false), "busy, you're in another app: covered")
check(!FocusRule.covers(status: .busy, windowIsFront: true, terminalActive: true), "the window you type in: open")
check(!FocusRule.covers(status: .waiting, windowIsFront: false, terminalActive: true), "needs you: open")
check(!FocusRule.covers(status: .idle, windowIsFront: false, terminalActive: false), "your turn: open")
check(!FocusRule.covers(status: .error, windowIsFront: false, terminalActive: false), "error: open")
check(!FocusRule.covers(status: .new, windowIsFront: false, terminalActive: false), "new session (your first prompt): open")
check(!FocusRule.covers(status: .ended, windowIsFront: false, terminalActive: false), "ended: open")
check(IslandConfig(raw: [:]).focusMode == false, "focus mode is off by default")
check(IslandConfig(raw: ["focusMode": .bool(true)]).focusMode, "focusMode from config")
// "Stay covered when it's your turn" (focusIdle): idle windows keep their cover, nothing else changes
check(FocusRule.covers(status: .idle, windowIsFront: false, terminalActive: true, idle: true), "your turn, staying covered: covered")
check(FocusRule.covers(status: .idle, windowIsFront: true, terminalActive: false, idle: true), "your turn, you're in another app: covered")
check(!FocusRule.covers(status: .idle, windowIsFront: true, terminalActive: true, idle: true), "your turn in the window you type in: open")
check(FocusRule.covers(status: .busy, windowIsFront: false, terminalActive: true, idle: true), "working, staying covered: covered")
for status in [SessionStatus.waiting, .error, .new, .ended, .unknown] {
    check(!FocusRule.covers(status: status, windowIsFront: false, terminalActive: false, idle: true), "\(status), staying covered: open")
}
check(IslandConfig(raw: [:]).focusIdle, "staying covered when it's your turn is on by default")
check(!IslandConfig(raw: ["focusIdle": .bool(false)]).focusIdle, "and can be turned off")
// A tty from a record is handed to osascript: only a device path gets there
check(SnapshotLoader.devicePath("/dev/ttys003") == "/dev/ttys003" && SnapshotLoader.devicePath("/dev/pts/4") == "/dev/pts/4", "a tty is a device path")
for bad in ["-e", "-e do shell script \"id\"", "ttys003", "/dev/ttys003; rm -rf ~", "/dev/tty s", "/tmp/x", "/dev/" + String(repeating: "a", count: 80)] {
    check(SnapshotLoader.devicePath(bad) == nil, "not a tty: \(bad)")
}
// A hand-edited config can't bind a global shortcut that swallows a plain key
let bareKey = IslandConfig(raw: ["islandShortcuts": .object(["watermark": .string("w"), "toggle": .string("shift+a"), "next": .string("f5"), "tile": .string("ctrl+opt+g")])])
check(bareKey.shortcuts[.watermark] == ShortcutAction.watermark.defaultCombo, "a shortcut without ⌃, ⌥ or ⌘ keeps the default")
check(bareKey.shortcuts[.toggle] == ShortcutAction.toggle.defaultCombo, "shift alone isn't enough")
check(bareKey.shortcuts[.next] == KeyCombo(spec: "f5"), "a function key may stand alone")
check(bareKey.shortcuts[.tile] == KeyCombo(spec: "ctrl+opt+g"), "a full shortcut from config")
check(IslandConfig(raw: ["focusIdle": .bool(true)]).focusIdle, "focusIdle from config")

// Subagents: running until their transcript ends with a final answer (shapes from real transcripts)
let agentStart = [
    #"{"type":"fork-context-ref","agentId":"a1","parentSessionId":"s"}"#,
]
check(SubagentScanner.state(ofLines: agentStart) == (true, nil), "just started")
let agentWorking = agentStart + [
    #"{"isSidechain":true,"agentId":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}],"stop_reason":"tool_use"},"type":"assistant"}"#,
    #"{"isSidechain":true,"agentId":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"type":"user"}"#,
]
let working1 = SubagentScanner.state(ofLines: agentWorking)
check(working1.running && working1.tool == "$ ls", "after a tool result: running, last step $ ls (\(working1))")
let agentThinking = agentWorking + [
    #"{"isSidechain":true,"agentId":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Now the tests."}],"stop_reason":null},"type":"assistant"}"#,
    #"{"isSidechain":true,"agentId":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{}}],"stop_reason":"tool_use"},"type":"assistant"}"#,
]
check(SubagentScanner.state(ofLines: agentThinking) == (true, "Editing a file"), "mid-turn text then Edit")
let agentDone = agentThinking + [
    #"{"isSidechain":true,"agentId":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]},"type":"user"}"#,
    #"{"isSidechain":true,"agentId":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Done: 3 files."}],"stop_reason":"end_turn"},"type":"assistant"}"#,
]
check(SubagentScanner.state(ofLines: agentDone).running == false, "final answer: finished")
let halfWritten = "{\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"te"
check(SubagentScanner.state(ofLines: agentDone + [halfWritten]).running == false, "a half-written line is skipped")
let agentResumed = agentDone + [
    #"{"isSidechain":true,"agentId":"a1","message":{"role":"user","content":"one more thing"},"type":"user"}"#,
]
check(SubagentScanner.state(ofLines: agentResumed).running, "sent another message: running again")
// Endings seen in real transcripts that aren't `end_turn` but are finished
let apiError = agentWorking + [
    #"{"isSidechain":true,"isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"API Error: rate limited"}],"stop_reason":"stop_sequence"},"type":"assistant"}"#,
]
check(!SubagentScanner.state(ofLines: apiError).running, "died on an API error: finished")
let interrupted = agentWorking + [
    #"{"isSidechain":true,"message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"type":"user"}"#,
]
check(!SubagentScanner.state(ofLines: interrupted).running, "interrupted: finished")
let notified = agentDone + [
    #"{"isSidechain":true,"message":{"role":"user","content":"[SYSTEM NOTIFICATION - NOT USER INPUT]\nA background task finished."},"type":"user"}"#,
]
check(!SubagentScanner.state(ofLines: notified).running, "a notification after the final answer: still finished")
let oldFinal = agentWorking + [
    #"{"isSidechain":true,"version":"2.1.268","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"stop_reason":null},"type":"assistant"}"#,
]
check(SubagentScanner.state(ofLines: oldFinal, quiet: 5).running, "no stop reason, just written: maybe mid-turn")
check(!SubagentScanner.state(ofLines: oldFinal, quiet: 90).running, "no stop reason (before 2.1.279), quiet 90 s: finished")
let midTurn = agentWorking + [
    #"{"isSidechain":true,"version":"2.1.283","message":{"role":"assistant","content":[{"type":"text","text":"Now the big file."}],"stop_reason":null},"type":"assistant"}"#,
]
check(SubagentScanner.state(ofLines: midTurn, quiet: 180).running, "mid-turn text (2.1.283), a long tool input on the way: running")
check(!SubagentScanner.state(ofLines: midTurn, quiet: 700).running, "mid-turn text quiet for 10 minutes: finished")

// Subagents on disk: <transcript>/subagents/agent-<id>.jsonl + .meta.json
let focusDir = FileManager.default.temporaryDirectory.appendingPathComponent("tabby-focus-\(getpid())")
let subDir = focusDir.appendingPathComponent("s1/subagents")
try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: focusDir.appendingPathComponent("s1.jsonl").path, contents: Data())
func writeAgent(_ id: String, _ lines: [String], description: String, type: String) {
    FileManager.default.createFile(atPath: subDir.appendingPathComponent("agent-\(id).jsonl").path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
    FileManager.default.createFile(atPath: subDir.appendingPathComponent("agent-\(id).meta.json").path,
                                   contents: Data(#"{"agentType":"\#(type)","description":"\#(description)","toolUseId":"t"}"#.utf8))
}
writeAgent("a1", agentWorking, description: "Find the call sites", type: "Explore")
writeAgent("a2", agentDone, description: "Write tests", type: "general-purpose")
let scanner = SubagentScanner()
let found = scanner.running(transcript: focusDir.appendingPathComponent("s1.jsonl").path)
check(found.count == 1 && found.first?.id == "a1" && found.first?.label == "Find the call sites" && found.first?.kind == "Explore"
      && found.first?.tool == "$ ls", "running subagents from disk: \(found)")
let later = scanner.running(transcript: focusDir.appendingPathComponent("s1.jsonl").path,
                            now: Date().addingTimeInterval(SubagentScanner.staleAfter + 5))
check(later.isEmpty, "a subagent quiet for 15 minutes is taken for dead")
check(scanner.running(transcript: focusDir.appendingPathComponent("none.jsonl").path).isEmpty, "no subagents folder")
try? FileManager.default.removeItem(at: focusDir)

// The cover's layout: the title is big but under the watermark's size, and everything fits
MainActor.assumeIsolated {
    var cover = FocusCoverContent(sessionId: "s", title: "Migrate billing to Stripe v3", project: "billing",
                                  background: .black, foreground: .white, accent: .orange, mainText: "working",
                                  mainDetail: nil, turnStartedAt: nil, agents: [])
    for size in [CGSize(width: 760, height: 460), CGSize(width: 845, height: 1316), CGSize(width: 1400, height: 380), CGSize(width: 480, height: 620)] {
        let bounds = CGRect(origin: .zero, size: size)
        guard let layout = FocusLayout.make(cover, in: bounds, agentCount: 3) else {
            check(false, "layout at \(size)")
            continue
        }
        let titleSize = (layout.title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        check(titleSize >= 20 && titleSize <= min(96, size.height * 0.12), "title \(titleSize)pt at \(size)")
        check(bounds.contains(layout.box) && bounds.contains(layout.lines), "box and lines inside at \(size)")
        check(layout.titleRect.minY >= layout.box.minY && layout.titleRect.maxY <= layout.box.maxY, "title inside the box at \(size)")
        check(layout.maxLines >= 3, "room for 3 agent lines at \(size)")
    }
    cover.title = "Supercalifragilisticexpialidocious refactor"
    let narrow = FocusLayout.make(cover, in: CGRect(x: 0, y: 0, width: 420, height: 400), agentCount: 1)
    check(narrow != nil, "a long word still fits a narrow window")
    check(FocusLayout.make(cover, in: CGRect(x: 0, y: 0, width: 400, height: 180), agentCount: 1)?.compact == true, "short window: title only")
    check(FocusCoverView.elapsed(9) == "9s" && FocusCoverView.elapsed(125) == "2m 05s" && FocusCoverView.elapsed(3_900) == "1h 05m", "elapsed format")
    // Your turn: a button under one line, inside the cover and clear of the box, the line and the hint
    cover.title = "Migrate billing to Stripe v3"
    check(FocusLayout.make(cover, in: CGRect(x: 0, y: 0, width: 760, height: 460), agentCount: 1)?.button == nil, "no button while Claude works")
    cover.yourTurn = true
    for size in [CGSize(width: 760, height: 460), CGSize(width: 845, height: 1316), CGSize(width: 1400, height: 380), CGSize(width: 480, height: 620),
                 CGSize(width: 760, height: 300), CGSize(width: 420, height: 220), CGSize(width: 300, height: 400)] {
        let bounds = CGRect(origin: .zero, size: size)
        guard let layout = FocusLayout.make(cover, in: bounds, agentCount: 1), layout.button != nil else {
            check(false, "your turn: a button at \(size)")
            continue
        }
        check(bounds.contains(layout.buttonRect), "your turn: button inside at \(size)")
        check(!layout.buttonRect.intersects(layout.titleRect) && !layout.buttonRect.intersects(layout.box), "your turn: button clear of the title at \(size)")
        check(layout.maxLines <= 1, "your turn: one line at most at \(size)")
        if layout.maxLines == 1 {
            let line = CGRect(x: layout.lines.minX, y: layout.lines.minY, width: layout.lines.width, height: layout.rowHeight)
            check(!layout.buttonRect.intersects(line), "your turn: button under the line at \(size)")
        }
        if layout.hint != nil { check(!layout.buttonRect.intersects(layout.hintRect), "your turn: button clear of the hint at \(size)") }
        check((layout.button?.size().width ?? 0) <= layout.buttonRect.width, "your turn: label fits its button at \(size)")
    }
    var session = working
    session.status = .idle
    session.activityAt = 1_000_000
    let turn = FocusCoverContent.make(session, themes: [], globalTheme: nil, now: Date(timeIntervalSince1970: 1_600))
    check(turn.yourTurn && turn.doneAt == 1_000 && turn.agents.isEmpty, "an idle session's cover says your turn")
    session.status = .busy
    check(!FocusCoverContent.make(session, themes: [], globalTheme: nil).yourTurn, "a working session's cover doesn't")
    cover.yourTurn = false
    check(FocusCoverView.who("general-purpose") == "agent" && FocusCoverView.who("Explore") == "explore"
          && FocusCoverView.who("code-reviewer") == "code-re…" && FocusCoverView.who(nil) == "agent", "agent type column")
    // The cover leaves Terminal's title bar (and tab bar) uncovered: measured, never shown.
    _ = NSApplication.shared
    check(TerminalChrome.titleBar >= 22 && TerminalChrome.titleBar <= 40, "title bar \(TerminalChrome.titleBar)")
    check(TerminalChrome.tabBar >= 20 && TerminalChrome.tabBar <= 48, "tab bar \(TerminalChrome.tabBar)")
    // Full screen, including below the notch of a built-in display (1512×982, 32 pt safe area)
    let notched = (frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: CGFloat(32))
    let plain = (frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), topInset: CGFloat(0))
    check(TerminalChrome.isFullScreen(CGRect(x: 0, y: 0, width: 1512, height: 950), screens: [notched, plain]), "full screen below the notch")
    check(TerminalChrome.isFullScreen(CGRect(x: 0, y: 0, width: 1512, height: 982), screens: [notched]), "full screen over the whole notched display")
    check(TerminalChrome.isFullScreen(CGRect(x: 1512, y: 0, width: 2560, height: 1440), screens: [notched, plain]), "full screen on a plain display")
    check(!TerminalChrome.isFullScreen(CGRect(x: 0, y: 0, width: 1512, height: 900), screens: [notched, plain]), "a tall window isn't full screen")
    check(!TerminalChrome.isFullScreen(CGRect(x: 1512, y: 0, width: 2560, height: 1408), screens: [notched, plain]), "no notch, no allowance")
}
// The hover dropdown's words
var asking = working
asking.status = .waiting
asking.waitingFor = "permission"
check(SessionDetailCopy.headline(asking, now: nowDate) == "Needs your permission to continue", "permission headline")
asking.waitingFor = "input"
check(SessionDetailCopy.headline(asking, now: nowDate) == "Asked you a question", "question headline")
asking.waitingFor = nil
check(SessionDetailCopy.headline(asking, now: nowDate) == "Waiting for you", "plain waiting headline")
check(SessionDetailCopy.hint(asking, now: nowDate, progress: false) == "Click the row to answer in its terminal.", "waiting hint")
var busy = working
busy.status = .busy
check(SessionDetailCopy.headline(busy, now: nowDate) == "Working for 4m", "busy headline: \(SessionDetailCopy.headline(busy, now: nowDate))")
check(SessionDetailCopy.hint(busy, now: nowDate, progress: false) == nil, "the row already shows progress")
check(SessionDetailCopy.hint(busy, now: nowDate, progress: true) == "~4m left · usually 8m", "one-line mode shows it in the card")
busy.lastPrompt = "<task-notification><task-id>x</task-id></task-notification>"
check(busy.typedPrompt == nil, "injected messages aren't prompts")
busy.lastPrompt = "  fix the flaky test  "
check(busy.typedPrompt == "fix the flaky test", "typed prompt")
check(TerminalKind(term: "apple-terminal") == .terminal && TerminalKind(term: nil) == .terminal, "Terminal.app")
check(TerminalKind(term: "iterm2") == .iTerm && TerminalKind(term: "iterm.app") == .iTerm, "iTerm2")
check(TerminalKind(term: "ghostty").label == "Ghostty" && !TerminalKind(term: "ghostty").closesTabs, "Ghostty keeps its tab")
check(TerminalKind(term: "iterm2").closesTabs && TerminalKind(term: "apple-terminal").closesTabs, "closes Terminal and iTerm2 tabs")
busy.term = "ghostty"
check(SessionDetailCopy.endConsequence(busy).contains("Its Ghostty tab stays open"), "consequence names the terminal")

// Ending a session: only that Claude process, in that tab
let started = Date(timeIntervalSince1970: 1_790_584_680)
let fine = SessionEndGuard.Observed(running: true, command: "claude", arguments: ["claude", "--continue"], tty: "/dev/ttys002",
                                    startedAt: started, registrySessionId: "abc", registryProcStart: "Mon Sep 28 08:38:00 2026")
let startedMs = 1_790_584_681_969.0
check(SessionEndGuard.verdict(sessionId: "abc", tty: "/dev/ttys002", startedAtMs: startedMs, observed: fine) == .end, "the right process")
check(SessionEndGuard.verdict(sessionId: "abc", tty: "ttys002", startedAtMs: startedMs, observed: fine) == .end, "tty without /dev/")
var gone = fine
gone.running = false
check(SessionEndGuard.verdict(sessionId: "abc", tty: "/dev/ttys002", startedAtMs: startedMs, observed: gone) == .gone, "already ended")
var other = fine
other.command = "zsh"
other.arguments = ["-zsh"]
check(SessionEndGuard.verdict(sessionId: "abc", tty: "/dev/ttys002", startedAtMs: startedMs, observed: other) != .end, "not claude")
var moved = fine
moved.tty = "/dev/ttys009"
check(SessionEndGuard.verdict(sessionId: "abc", tty: "/dev/ttys002", startedAtMs: startedMs, observed: moved) != .end, "other tty")
check(SessionEndGuard.verdict(sessionId: "abc", tty: nil, startedAtMs: startedMs, observed: fine) != .end, "unknown tty")
var reused = fine
reused.startedAt = started.addingTimeInterval(3_600)
reused.registryProcStart = nil
check(SessionEndGuard.verdict(sessionId: "abc", tty: "/dev/ttys002", startedAtMs: startedMs, observed: reused) != .end, "pid reused later")
var disagree = fine
disagree.registryProcStart = "Mon Sep 28 07:00:00 2026"
check(SessionEndGuard.verdict(sessionId: "abc", tty: "/dev/ttys002", startedAtMs: startedMs, observed: disagree) != .end, "registry start differs")
var cleared = fine
cleared.registrySessionId = "after-clear"
check(SessionEndGuard.verdict(sessionId: "abc", tty: "/dev/ttys002", startedAtMs: startedMs, observed: cleared) == .end, "/clear keeps the process (start times agree)")
cleared.registryProcStart = nil
check(SessionEndGuard.verdict(sessionId: "abc", tty: "/dev/ttys002", startedAtMs: startedMs, observed: cleared) != .end, "no start time: the ids must agree")
check(SessionEndGuard.isClaude(command: "node", arguments: ["node", "/usr/local/bin/claude"]), "npm install")
check(SessionEndGuard.isClaude(command: "node", arguments: ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js"]), "npm cli.js")
check(!SessionEndGuard.isClaude(command: "node", arguments: ["node", "server.js", "claude"]), "node with a claude argument later")
check(!SessionEndGuard.isClaude(command: "claude-helper", arguments: ["claude-helper"]), "other binaries")
check(SessionEndGuard.procStartDates("Sat Sep  6 20:07:51 2026").count == 2, "padded day parses")

// The confirmation ignores the second click of a double-click on "End Session…"
let shown = Date(timeIntervalSince1970: 1_000)
check(!SessionEndGuard.confirmAccepts(shownAt: shown, now: shown.addingTimeInterval(0.15), doubleClickInterval: 0.5), "double-click's second click: ignored")
check(!SessionEndGuard.confirmAccepts(shownAt: shown, now: shown.addingTimeInterval(0.55), doubleClickInterval: 0.5), "still within the double-click window: ignored")
check(SessionEndGuard.confirmAccepts(shownAt: shown, now: shown.addingTimeInterval(0.7), doubleClickInterval: 0.5), "a deliberate click after it appears: ends")
check(!SessionEndGuard.confirmAccepts(shownAt: shown, now: shown.addingTimeInterval(0.9), doubleClickInterval: 1.0), "a slow double-click setting is respected")
check(!SessionEndGuard.confirmAccepts(shownAt: nil, now: shown, doubleClickInterval: 0.5), "no confirmation shown: never")
// Screens for Claude sessions (Settings › Windows), as lib/screens.js decides
let laptop = ScreenInfo(key: "LAPTOP", name: "Built-in", frame: CGRect(x: -1512, y: 0, width: 1512, height: 982), hasNotch: true)
let mainScreen = ScreenInfo(key: "MAIN", name: "HP", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isPrimary: true)
let vertical = ScreenInfo(key: "DELL", name: "Dell", frame: CGRect(x: 2560, y: -600, width: 1440, height: 2560))
let screens = ScreenInfo.sorted([mainScreen, vertical, laptop])
check(screens.map(\.key) == ["LAPTOP", "MAIN", "DELL"], "screens left to right: \(screens.map(\.key))")
check(vertical.isPortrait && !mainScreen.isPortrait, "portrait")
check(TileScreens(raw: nil) == .current && TileScreens(raw: .string("all")) == .all, "tileScreens default and all")
check(TileScreens(raw: .array([.string("DELL")])) == .chosen(["DELL"]), "tileScreens keys")
check(TileScreens(raw: .array([])) == .current, "no keys: the current screen")
check(TileScreens.chosen(["DELL", "GONE"]).config == .array([.string("DELL"), .string("GONE")]), "round trip")
check(TileScreens.current.used(screens, focused: "MAIN") == ["MAIN"], "current = the screen you're on")
check(TileScreens.chosen(["DELL"]).used(screens, focused: "MAIN") == ["DELL"], "only the vertical monitor")
check(TileScreens.chosen(["GONE"]).used(screens, focused: "MAIN") == ["MAIN"], "unplugged: falls back")
let picked = TileScreens.current.toggling("DELL", screens: screens, focused: "MAIN")
check(picked == .chosen(["MAIN", "DELL"]), "clicking adds to what's in use: \(picked)")
check(picked.toggling("MAIN", screens: screens, focused: "MAIN") == .chosen(["DELL"]), "and removes")
check(TileScreens.chosen(["DELL"]).toggling("DELL", screens: screens, focused: "MAIN") == .chosen(["DELL"]), "the last screen stays")
check(TileScreens.chosen(["GONE", "DELL"]).toggling("MAIN", screens: screens, focused: nil) == .chosen(["GONE", "DELL", "MAIN"]),
      "an unplugged pick is kept")
check(TileScope(raw: .string("active")) == .active && TileScope(raw: nil) == .all, "tileScope")

// Tiling some sessions
var tileable = working
tileable.tty = "/dev/ttys004"
tileable.term = "apple-terminal"
tileable.status = .waiting
check(tileable.isTileable && tileable.isActive, "Terminal session waiting on you: tileable, active")
tileable.term = "vscode"
check(!tileable.isTileable, "VS Code can't be tiled")
tileable.status = .idle
check(!tileable.isActive, "your turn isn't active")
check(tileable.tileToken == "w", "tile --only by session id")

// Quick launch
let folders = RecentFolder.parse("""
[{"path":"/w/wildcat","name":"wildcat","display":"~/w/wildcat","sessions":31,"live":1,"lastUsed":0},
 {"path":"/w/tabby","name":"tabby","display":"~/w/tabby","sessions":2,"live":0,"lastUsed":0},
 {"path":"/w/lab/cat-tools","name":"cat-tools","display":"~/w/lab/cat-tools","sessions":1}]
""")
check(folders.count == 3 && folders[0].countText == "1 running" && folders[1].countText == "2 sessions", "parse \(folders)")
check(QuickLaunchFilter.apply("", to: folders).map(\.name) == ["wildcat", "tabby", "cat-tools"], "empty: frecency order")
check(QuickLaunchFilter.apply("cat", to: folders).map(\.name) == ["cat-tools", "wildcat"], "prefix first, then contains")
check(QuickLaunchFilter.apply("lab", to: folders).map(\.name) == ["cat-tools"], "matches the path too")
let typed = QuickLaunchFilter.apply("~/new-app", to: folders, home: "/Users/me", isDirectory: { $0 == "/Users/me/new-app" })
check(typed.first?.path == "/Users/me/new-app" && typed.first?.typed == true && typed.first?.display == "~/new-app", "a typed path: \(typed)")
check(QuickLaunchFilter.apply("/nope", to: folders, isDirectory: { _ in false }).isEmpty, "a path that doesn't exist")
let absolute = QuickLaunchFilter.apply("/w/tabby", to: folders, isDirectory: { _ in true })
check(absolute.first?.name == "tabby" && absolute.first?.typed == false && absolute.filter { $0.name == "tabby" }.count == 1,
      "a recent folder typed as an absolute path: that folder, once: \(absolute.map(\.path))")
let slashed = QuickLaunchFilter.apply("~/w/tabby/", to: folders, home: "", isDirectory: { _ in true })
check(slashed.first?.path == "/w/tabby" && slashed.first?.typed == false, "~ path with a trailing slash: \(slashed.map(\.path))")
check(QuickLaunchFilter.apply("tabby/", to: folders).first?.name == "tabby", "a name with a trailing slash")
check(QuickLaunchFilter.arguments(for: folders[1], name: "  Fix it ", skipPermissions: true) == ["new", "/w/tabby", "--name", "Fix it", "--dangerous"],
      "launch args")
check(QuickLaunchFilter.arguments(for: folders[1], name: "", skipPermissions: false) == ["new", "/w/tabby"], "plain launch")
check(ShortcutAction.launch.defaultCombo == KeyCombo(kVK_ANSI_L, [.control, .option]), "quick launch ⌃⌥L")
let defaults = ShortcutAction.allCases.map(\.defaultCombo)
check(Set(defaults).count == defaults.count, "no two default shortcuts collide")

// Tiling progress (the CLI's tile.lock) and the pills it makes
let tileDir = FileManager.default.temporaryDirectory.appendingPathComponent("tabby-island-tile-\(getpid())")
try? FileManager.default.createDirectory(at: tileDir.appendingPathComponent("tabby"), withIntermediateDirectories: true)
setenv("CLAUDE_CONFIG_DIR", tileDir.path, 1)
func writeLock(_ json: String) { try? json.write(to: TileProgress.file, atomically: true, encoding: .utf8) }
check(TileProgress.read() == nil, "no lock, no tile")
let nowMs = Int(Date().timeIntervalSince1970 * 1000)
writeLock(#"{"pid":\#(getpid()),"at":\#(nowMs),"text":"Splitting tabs","fraction":0.4,"step":2,"of":4}"#)
let reading = TileProgress.read()
check(reading == TileProgress(text: "Splitting tabs", fraction: 0.4, step: 2, of: 4), "read the lock: \(String(describing: reading))")
check(reading?.detail == "Splitting tabs · 2 of 4", "step detail")
check(TileProgress(text: "Placing 1 window", fraction: 0.75, step: 1, of: 1).detail == "Placing 1 window", "no '1 of 1'")
writeLock(#"{"pid":\#(getpid()),"at":\#(nowMs - 61_000),"text":"Old"}"#)
check(TileProgress.read() == nil, "a lock older than a minute is stale")
writeLock("\(getpid()) \(nowMs)")
check(TileProgress.read() == nil, "the old 'pid at' lock carries no progress")
try? FileManager.default.removeItem(at: tileDir)
unsetenv("CLAUDE_CONFIG_DIR")
check(TileProgress(text: "a", fraction: 0.3).after(TileProgress(text: "b", fraction: 0.6)).fraction == 0.6, "the ring never runs back")
let tilingPill = Announcement.tiling(TileProgress(text: "Checking windows", fraction: 0.1, step: 1, of: 3))
let nextPill = tilingPill.updated(with: TileProgress(text: "Splitting tabs", fraction: 0.3, step: 2, of: 3))
check(nextPill.id == tilingPill.id && nextPill.suffix == "Splitting tabs · 2 of 3" && nextPill.progress == 0.3,
      "the tiling pill updates in place")
check(tilingPill.duration > 60 && tilingPill.topic == "tile", "the tiling pill stays until the tile ends")
let tiledPill = Announcement.tiled(fromOutput: "Tiled 4 sessions in a 2×2 grid, each in its own color.\n")
check(tiledPill?.title == "Tiled 4 windows" && tiledPill?.suffix == "in new colors" && tiledPill?.success == true,
      "tile result: \(String(describing: tiledPill))")
check(Announcement.tiled(fromOutput: "Tiled 1 session in a 1×1 grid.")?.title == "Tiled 1 window"
      && Announcement.tiled(fromOutput: "Tiled 1 session in a 1×1 grid.")?.suffix == nil, "one window, colors off")
check(Announcement.tiled(fromOutput: "Nothing was tiled.") == nil, "nothing tiled: no success pill")
check(IslandConfig(raw: [:]).tileRecolor && !IslandConfig(raw: ["tileRecolor": .bool(false)]).tileRecolor, "tileRecolor setting")

// What a session is doing, and the gist of the reply that ended its turn (focus mode's cover)
check(ActivityDescriber.describe(tool: "Bash", input: ["command": "npm test", "description": "Run the test suite"]) == "Run the test suite",
      "a command's own description")
check(ActivityDescriber.describe(tool: "Bash", input: ["command": "git status\ngit diff"]) == "$ git status git diff", "else the command")
check(ActivityDescriber.describe(tool: "Edit", input: ["file_path": "/Users/me/app/lib/tile.js"]) == "Editing tile.js", "a file's name")
check(ActivityDescriber.describe(tool: "Grep", input: ["pattern": "tileRecolor"]) == "Searching for “tileRecolor”", "a search")
check(ActivityDescriber.describe(tool: "mcp__claude_ai_Gmail__search_threads", input: [:]) == "Gmail: search threads", "an MCP tool")
let turn = [
    #"{"type":"user","message":{"role":"user","content":"Fix the flaky test"}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Running the suite first:"}]}}"#,
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test","description":"Run the test suite"}}]}}"#,
]
check(TranscriptActivity.current(turn) == "Run the test suite", "the call still running: \(String(describing: TranscriptActivity.current(turn)))")
let answered = turn + [#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#]
check(TranscriptActivity.current(answered) == "Thinking", "its result is in: thinking")
check(TranscriptActivity.current(Array(turn.prefix(2))) == "Running the suite first", "what it wrote mid-turn")
check(TranscriptActivity.current(Array(turn.prefix(1))) == "Thinking", "just prompted")
check(TranscriptActivity.lastReply(turn) == nil, "no reply while a tool runs")
let finished = answered + [
    #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The flaky test is fixed: it waited on a real timer. **All 84 tests pass** now.\n\n## Details\n- `tile.test.js`: fake clock.\n\nWant me to commit it?"}],"stop_reason":"end_turn"}}"#,
    #"{"type":"system","subtype":"turn_duration","durationMs":5000}"#,
]
let gist = TranscriptActivity.lastReply(finished)
check(gist?.lead == "The flaky test is fixed: it waited on a real timer. All 84 tests pass now.", "lead: \(String(describing: gist))")
check(gist?.ask == "Want me to commit it?" && gist?.lines == 4, "ask and length: \(String(describing: gist))")
let request = ReplySummary.make("Add `API_KEY` to the staging settings.\n\n1. Open Settings.\n2. Add it.\n\nTell me when it's in, and I'll redeploy.")
check(request?.lead == "Add API_KEY to the staging settings." && request?.ask == "Tell me when it's in, and I'll redeploy.",
      "a request without a question mark: \(String(describing: request))")
check(ReplySummary.make("- **Done:** the island builds.\n- Tests pass.")?.lead == "Done: the island builds.", "a reply that's only a list")
check(ReplySummary.make(String(repeating: "word ", count: 120) + ".")!.lead.hasSuffix("…"), "a long opening is cut")
let failedReply = answered + [#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"API Error"}]},"isApiErrorMessage":true}"#]
check(TranscriptActivity.lastReply(failedReply) == nil, "an API error is no reply")

// "tabby-44 is done" said nothing: the pill names the session, then the project and what Claude did.
var finishedTurn = IslandSession(id: "f", sessionId: "f", pid: 1, cwd: "/x/wildcat", project: "wildcat", registryName: "wildcat-4f",
                                 title: "Fix Invoice Totals", titleSource: "ai", summary: "Fixing the invoice export.", note: nil,
                                 theme: nil, accentKey: nil, accentHex: nil, dotHex: nil, cursorHex: nil, status: .idle,
                                 waitingFor: nil, lastPrompt: "fix the invoice totals", context: nil, model: nil, tty: nil, term: nil,
                                 startedAt: 0, activityAt: nil, hasRecord: true)
check(Announcement.done(finishedTurn).subtitle == "wildcat · Fixing the invoice export.", "before the reply lands: the summary")
finishedTurn.reply = ReplySummary(lead: "Totals now match the order.", ask: nil, lines: 3)
check(Announcement.done(finishedTurn).subtitle == "wildcat · Totals now match the order.", "then what Claude said")
finishedTurn.title = "wildcat"
check(Announcement.done(finishedTurn).subtitle == "Totals now match the order.", "no project twice")
check(Announcement.done(finishedTurn).duration > Announcement.info("x").duration, "a second line stays up longer")
check(SnapshotLoader.saysNothing("wildcat-4f", standIn: "wildcat-4f") && SnapshotLoader.saysNothing("Claude Code", standIn: nil)
      && !SnapshotLoader.saysNothing("Fix Invoice Totals", standIn: "wildcat-4f"), "stand-in tab titles are skipped")

// History and Processes read what the CLI prints.
let past = PastSession.parse(##"[{"sessionId":"a","title":"Stripe","named":true,"project":"billing","cwd":"/x","summary":null,"lastPrompt":"retry it","prompts":2,"startedAt":1,"lastAt":1791000000000,"live":false,"status":"ended","accent":"#7fb0ea","dot":"#7fb0ea","resumable":true}]"##)
check(past?.first?.detail == "billing · You asked: retry it", "past session: \(String(describing: past))")
let scanText = #"{"at":1,"items":[{"id":"700-1","pid":700,"pids":[700],"label":"next dev","command":"x","ports":[3000,3001],"cpu":18.4,"memMB":1180,"startedAt":1,"count":1,"owner":{"kind":"claude","live":false,"sessionId":"s","title":"Dark Mode","project":"web"},"leftover":true,"stale":true,"why":"session ended","cwd":"/x/web","project":"web"}],"stale":{"count":1,"memMB":1180,"cpu":18.4}}"#
let scan = ProcessScan.parse(scanText)
check(scan?.items.first?.portText == ":3000 :3001" && scan?.items.first?.detail == "web · Dark Mode" && scan?.stale.count == 1,
      "process scan: \(String(describing: scan))")
check(Fmt.memory(1180) == "1.2 GB" && Fmt.memory(312) == "312 MB", "memory")
let stopped = StopResult.parse(#"{"stopped":[{"id":"1","pid":1,"label":"vite","ports":[],"memMB":300,"cpu":2}],"failed":[],"memMB":300,"cpu":2,"unknown":[]}"#)
check(stopped?.message == "Stopped vite · freed 300 MB", "stop result: \(stopped?.message ?? "nil")")
check(IslandPage.isPageRow(IslandPage.history.rowId("a")) && !IslandPage.isPageRow("a1b2-c3"), "page rows")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
