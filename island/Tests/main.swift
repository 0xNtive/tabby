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

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
