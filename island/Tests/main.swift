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

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
