import AppKit
import Carbon.HIToolbox

// MARK: - Key combos

/// ⌃ ⌥ ⇧ ⌘, in the order macOS shows them.
struct KeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let control = KeyModifiers(rawValue: 1)
    static let option = KeyModifiers(rawValue: 2)
    static let shift = KeyModifiers(rawValue: 4)
    static let command = KeyModifiers(rawValue: 8)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ flags: NSEvent.ModifierFlags) {
        var value: KeyModifiers = []
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        self = value
    }

    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") +
            (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    var carbon: UInt32 {
        var value = 0
        if contains(.control) { value |= controlKey }
        if contains(.option) { value |= optionKey }
        if contains(.shift) { value |= shiftKey }
        if contains(.command) { value |= cmdKey }
        return UInt32(value)
    }

    /// Parts of a config spec ("ctrl+opt+w").
    var specParts: [String] {
        (contains(.control) ? ["ctrl"] : []) + (contains(.option) ? ["opt"] : []) +
            (contains(.shift) ? ["shift"] : []) + (contains(.command) ? ["cmd"] : [])
    }
}

/// A physical key (ANSI key code) plus modifiers. Stored in config.json as "ctrl+opt+w".
struct KeyCombo: Hashable, Sendable {
    var keyCode: Int
    var modifiers: KeyModifiers

    init(_ keyCode: Int, _ modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// "ctrl+opt+w", "cmd+shift+f5". Nil for "", "none", "off" or anything unreadable.
    init?(spec: String) {
        let parts = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty, let key = KeyNames.code(for: last) else { return nil }
        var modifiers: KeyModifiers = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            case "cmd", "command", "⌘": modifiers.insert(.command)
            default: return nil
            }
        }
        self.init(key, modifiers)
    }

    var spec: String { (modifiers.specParts + [KeyNames.name(for: keyCode) ?? "\(keyCode)"]).joined(separator: "+") }

    /// "⌃⌥W"
    var display: String { modifiers.symbols + (KeyNames.label(for: keyCode) ?? "?") }

    /// For NSMenuItem.keyEquivalent (nil when the key has no character).
    var menuKey: String? { KeyNames.menuKey(for: keyCode) }

    var isDigit: Bool { KeyNames.digits.contains(keyCode) }
    var isFunctionKey: Bool { KeyNames.functionKeys.contains(keyCode) }
}

/// The keys a shortcut can use, by physical (ANSI) position.
enum KeyNames {
    private struct Key {
        let name: String
        let code: Int
        let label: String
        let menu: String?
    }

    private static func function(_ n: Int) -> String? {
        UnicodeScalar(NSF1FunctionKey + n - 1).map { String(Character($0)) }
    }

    private static func special(_ key: Int) -> String? {
        UnicodeScalar(key).map { String(Character($0)) }
    }

    private static let keys: [Key] = {
        var keys: [Key] = []
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z),
        ]
        keys += letters.map { Key(name: $0.0, code: $0.1, label: $0.0.uppercased(), menu: $0.0) }
        keys += zip(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], digitsInOrder).map {
            Key(name: $0.0, code: $0.1, label: $0.0, menu: $0.0)
        }
        let punctuation: [(String, Int)] = [
            (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash), (";", kVK_ANSI_Semicolon),
            ("'", kVK_ANSI_Quote), ("[", kVK_ANSI_LeftBracket), ("]", kVK_ANSI_RightBracket),
            ("\\", kVK_ANSI_Backslash), ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("`", kVK_ANSI_Grave),
        ]
        keys += punctuation.map { Key(name: $0.0, code: $0.1, label: $0.0, menu: $0.0) }
        keys += [
            Key(name: "space", code: kVK_Space, label: "Space", menu: " "),
            Key(name: "return", code: kVK_Return, label: "↩", menu: "\r"),
            Key(name: "tab", code: kVK_Tab, label: "⇥", menu: "\t"),
            Key(name: "left", code: kVK_LeftArrow, label: "←", menu: special(NSLeftArrowFunctionKey)),
            Key(name: "right", code: kVK_RightArrow, label: "→", menu: special(NSRightArrowFunctionKey)),
            Key(name: "up", code: kVK_UpArrow, label: "↑", menu: special(NSUpArrowFunctionKey)),
            Key(name: "down", code: kVK_DownArrow, label: "↓", menu: special(NSDownArrowFunctionKey)),
        ]
        keys += zip(1...12, functionKeysInOrder).map { Key(name: "f\($0.0)", code: $0.1, label: "F\($0.0)", menu: function($0.0)) }
        return keys
    }()

    private static let digitsInOrder = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    private static let functionKeysInOrder = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                                              kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]

    /// ⌃⌥1 … ⌃⌥9, in order.
    static let jumpDigits = Array(digitsInOrder.dropFirst())
    static let digits = Set(digitsInOrder)
    static let functionKeys = Set(functionKeysInOrder)

    private static let byName = Dictionary(keys.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    private static let byCode = Dictionary(keys.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })

    static func code(for name: String) -> Int? {
        let aliases = ["spacebar": "space", "enter": "return", "comma": ",", "period": ".", "slash": "/"]
        return byName[aliases[name] ?? name]?.code
    }

    static func name(for code: Int) -> String? { byCode[code]?.name }
    static func label(for code: Int) -> String? { byCode[code]?.label }
    static func menuKey(for code: Int) -> String? { byCode[code]?.menu }
}

// MARK: - What the shortcuts do

/// The island's global shortcuts (`islandShortcuts` in config.json overrides the defaults).
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case toggle, next, jump, tile, mode, watermark, settings

    var id: String { rawValue }

    /// Settings and the README.
    var title: String {
        switch self {
        case .toggle: return "Open the island with the keyboard"
        case .next: return "Jump to the next session that needs you"
        case .jump: return "Jump to session 1–9"
        case .tile: return "Tile session windows"
        case .mode: return "Switch the island's detail level"
        case .watermark: return "Show or hide the watermark"
        case .settings: return "Open Settings"
        }
    }

    /// The status menu (title case, short).
    var menuTitle: String {
        switch self {
        case .toggle: return "Open Island with Keyboard"
        case .next: return "Next Session That Needs You"
        case .jump: return "Jump to Session 1–9"
        case .tile: return "Tile Windows"
        case .mode: return "Cycle Mode"
        case .watermark: return "Toggle Watermark"
        case .settings: return "Settings…"
        }
    }

    var defaultCombo: KeyCombo {
        let hyper: KeyModifiers = [.control, .option]
        switch self {
        case .toggle: return KeyCombo(kVK_Space, hyper)
        case .next: return KeyCombo(kVK_ANSI_N, hyper)
        case .jump: return KeyCombo(kVK_ANSI_1, hyper)
        case .tile: return KeyCombo(kVK_ANSI_G, hyper)
        case .mode: return KeyCombo(kVK_ANSI_M, hyper)
        case .watermark: return KeyCombo(kVK_ANSI_W, hyper)
        case .settings: return KeyCombo(kVK_ANSI_Comma, hyper)
        }
    }

    static var defaults: [ShortcutAction: KeyCombo] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultCombo) })
    }

    /// "⌃⌥W", or "⌃⌥1…9" for the jump digits.
    func display(_ combo: KeyCombo?) -> String {
        guard let combo else { return "None" }
        return self == .jump ? "\(combo.modifiers.symbols)1…9" : combo.display
    }

    /// Does `combo` (for this action) collide with `other` (for `action`)? The jump shortcut
    /// takes all nine digits with its modifiers.
    func collides(_ combo: KeyCombo, with other: KeyCombo, of action: ShortcutAction) -> Bool {
        switch (self == .jump, action == .jump) {
        case (true, true): return combo.modifiers == other.modifiers
        case (true, false): return other.modifiers == combo.modifiers && KeyNames.jumpDigits.contains(other.keyCode)
        case (false, true): return combo.modifiers == other.modifiers && KeyNames.jumpDigits.contains(combo.keyCode)
        case (false, false): return combo == other
        }
    }
}

extension [ShortcutAction: KeyCombo] {
    /// `islandShortcuts`: only what differs from the defaults ("" turns a shortcut off).
    var overrides: [String: ConfigValue] {
        var out: [String: ConfigValue] = [:]
        for action in ShortcutAction.allCases where self[action] != action.defaultCombo {
            out[action.rawValue] = .string(self[action]?.spec ?? "")
        }
        return out
    }
}
