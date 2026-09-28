import AppKit

// The model behind Settings › Windows, tiling some sessions, and quick launch (no UI here, so
// island/test.sh can check it).

// MARK: - Displays

/// A display, for choosing where Claude sessions go. Its key matches lib/screens.js: the display
/// UUID (stable across reconnects), or "name@WxH" when macOS has none.
struct ScreenInfo: Identifiable, Equatable, Sendable {
    let key: String
    let name: String
    /// Global frame in Cocoa coordinates (origin at the bottom-left of the menu-bar screen).
    let frame: CGRect
    let isPrimary: Bool
    let isBuiltin: Bool
    let hasNotch: Bool

    var id: String { key }
    var isPortrait: Bool { frame.height > frame.width }
    var sizeText: String { "\(Int(frame.width))×\(Int(frame.height))" }

    /// Snapshot renders draw made-up screens.
    @MainActor static var override: [ScreenInfo]?

    /// Every display, left to right then top to bottom: the order `tabby tile screens` numbers them.
    @MainActor static func current() -> [ScreenInfo] {
        if let override { return override }
        return sorted(NSScreen.screens.enumerated().map { ScreenInfo(screen: $0.element, primary: $0.offset == 0) })
    }

    static func sorted(_ screens: [ScreenInfo]) -> [ScreenInfo] {
        screens.sorted { ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY) }
    }

    /// The screen you're working on (NSScreen.main, as the CLI's "current").
    @MainActor static func focusedKey(in screens: [ScreenInfo]) -> String? {
        if override != nil { return screens.first(where: \.isPrimary)?.key }
        guard let main = NSScreen.main else { return screens.first?.key }
        return ScreenInfo(screen: main, primary: main == NSScreen.screens.first).key
    }

    init(key: String, name: String, frame: CGRect, isPrimary: Bool = false, isBuiltin: Bool = false, hasNotch: Bool = false) {
        self.key = key
        self.name = name
        self.frame = frame
        self.isPrimary = isPrimary
        self.isBuiltin = isBuiltin
        self.hasNotch = hasNotch
    }

    init(screen: NSScreen, primary: Bool) {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let name = screen.localizedName
        var key = "\(name)@\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) as String? {
            key = text
        }
        self.init(key: key, name: name, frame: screen.frame, isPrimary: primary,
                  isBuiltin: CGDisplayIsBuiltin(number) != 0, hasNotch: screen.safeAreaInsets.top > 0)
    }
}

/// `tileScreens` in config.json: where tiling and new sessions put windows.
enum TileScreens: Equatable, Sendable {
    /// The screen you're on (the default).
    case current
    case all
    /// These screens (keys); an unplugged one is skipped.
    case chosen([String])

    init(raw: ConfigValue?) {
        switch raw {
        case .string(let value) where value.lowercased() == "all": self = .all
        case .array(let values):
            let keys = values.compactMap(\.string)
            self = keys.isEmpty ? .current : .chosen(keys)
        default: self = .current
        }
    }

    var config: ConfigValue {
        switch self {
        case .current: return .string("current")
        case .all: return .string("all")
        case .chosen(let keys): return .array(keys.map { .string($0) })
        }
    }

    /// Which of `screens` get Claude sessions (as chooseScreens in lib/screens.js decides).
    func used(_ screens: [ScreenInfo], focused: String?) -> Set<String> {
        let fallback = Set([focused ?? screens.first?.key].compactMap { $0 })
        switch self {
        case .current: return fallback
        case .all: return Set(screens.map(\.key))
        case .chosen(let keys):
            let connected = Set(keys).intersection(screens.map(\.key))
            return connected.isEmpty ? fallback : connected
        }
    }

    /// Clicking a screen on the map: from what's in use now (a picked screen that's unplugged
    /// stays picked), add or remove it. The last connected one stays: sessions have to go somewhere.
    func toggling(_ key: String, screens: [ScreenInfo], focused: String?) -> TileScreens {
        var keys: [String]
        if case .chosen(let picked) = self {
            keys = picked
        } else {
            let used = used(screens, focused: focused)
            keys = screens.map(\.key).filter(used.contains)
        }
        if let index = keys.firstIndex(of: key) {
            let connected = keys.filter { key in screens.contains { $0.key == key } }
            guard connected.count > 1 else { return self }
            keys.remove(at: index)
        } else {
            keys.append(key)
        }
        return .chosen(keys)
    }

    enum Kind: String, CaseIterable, Identifiable {
        case current, all, chosen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .current: return "The screen you're on"
            case .all: return "All screens"
            case .chosen: return "Screens I pick"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .current: return .current
        case .all: return .all
        case .chosen: return .chosen
        }
    }
}

/// `tileScope`: what ⌃⌥G and the tile button tile.
enum TileScope: String, CaseIterable, Identifiable, Sendable {
    case all, active
    var id: String { rawValue }
    var title: String { self == .all ? "Every session" : "Only active ones: working or waiting on you" }

    init(raw: ConfigValue?) {
        self = raw?.string?.lowercased() == "active" ? .active : .all
    }
}

extension IslandSession {
    /// Tiling moves Terminal.app and iTerm2 windows only.
    var isTileable: Bool { tty != nil && (term == "apple-terminal" || term == "iterm2") }
    /// Working, or waiting on you (the CLI's `--active`).
    var isActive: Bool { status == .busy || status == .waiting }
    /// How `tabby tile --only` finds it.
    var tileToken: String { sessionId ?? tty ?? String(pid) }
}

// MARK: - Quick launch

/// A folder quick launch offers (`tabby new --list --json`).
struct RecentFolder: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    /// `~/…`
    let display: String
    var sessions = 0
    var live = 0
    var lastUsed: Double = 0
    /// Typed as a path rather than found among the recent ones.
    var typed = false

    var id: String { path }

    static func parse(_ json: String) -> [RecentFolder] {
        guard let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let path = row["path"] as? String else { return nil }
            return RecentFolder(path: path, name: row["name"] as? String ?? (path as NSString).lastPathComponent,
                                display: row["display"] as? String ?? path,
                                sessions: (row["sessions"] as? NSNumber)?.intValue ?? 0,
                                live: (row["live"] as? NSNumber)?.intValue ?? 0,
                                lastUsed: (row["lastUsed"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    /// "3 running", "31 sessions", "1 session"
    var countText: String {
        if live > 0 { return "\(live) running" }
        return "\(sessions) session\(sessions == 1 ? "" : "s")"
    }

    /// "now", "12m ago", "3h ago", "2d ago"
    func agoText(now: Date = Date()) -> String {
        guard lastUsed > 0 else { return "" }
        let minutes = max(0, Int((now.timeIntervalSince1970 * 1000 - lastUsed) / 60_000))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 1440 { return "\(minutes / 60)h ago" }
        return "\(minutes / 1440)d ago"
    }
}

enum QuickLaunchFilter {
    /// Folders matching what's typed, best first: a name that starts with it, then a name that
    /// contains it, then a path that does (each keeps the frecency order). A typed path that
    /// exists comes first. Empty: everything, in frecency order.
    static func apply(_ query: String, to folders: [RecentFolder], home: String = NSHomeDirectory(),
                      isDirectory: (String) -> Bool = QuickLaunchFilter.isDirectory) -> [RecentFolder] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return folders }
        var out: [RecentFolder] = []
        if q.hasPrefix("/") || q.hasPrefix("~") {
            let path = q.hasPrefix("~") ? home + q.dropFirst() : q
            let clean = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            if isDirectory(clean), !folders.contains(where: { $0.path == clean }) {
                let display = clean.hasPrefix(home + "/") ? "~" + clean.dropFirst(home.count) : clean
                out.append(RecentFolder(path: clean, name: (clean as NSString).lastPathComponent, display: display, typed: true))
            }
        }
        let lower = q.lowercased()
        let starts = folders.filter { $0.name.lowercased().hasPrefix(lower) }
        let contains = folders.filter { !$0.name.lowercased().hasPrefix(lower) && $0.name.lowercased().contains(lower) }
        let inPath = folders.filter { !$0.name.lowercased().contains(lower) && $0.display.lowercased().contains(lower) }
        return out + starts + contains + inPath
    }

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// `tabby new` arguments for a launch.
    static func arguments(for folder: RecentFolder, name: String, skipPermissions: Bool) -> [String] {
        var args = ["new", folder.path]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { args += ["--name", trimmed] }
        if skipPermissions { args.append("--dangerous") }
        return args
    }
}
