import AppKit
import ApplicationServices

// MARK: - Actions (tabby CLI + tab focusing)

@MainActor
enum Actions {
    static weak var store: SessionStore?

    static func setColor(_ session: IslandSession, key: String) {
        runCLI(["color", key, "--session", session.cliTarget])
    }

    static func setTheme(_ session: IslandSession, id: String) {
        runCLI(["theme", id, "--session", session.cliTarget])
    }

    static func setThemeAll(_ id: String) {
        runCLI(["theme", id, "--all"])
    }

    static func rename(_ session: IslandSession, to name: String) {
        runCLI(["name", name, "--session", session.cliTarget])
    }

    static func renameWithAI(_ session: IslandSession) {
        runCLI(["name", "--auto", "--session", session.cliTarget])
    }

    static func resetLook(_ session: IslandSession) {
        runCLI(["reset", "--session", session.cliTarget])
    }

    /// `tabby config <key> <json>`: the CLI JSON-parses the value.
    static func setConfig(_ key: String, json: String) {
        runCLI(["config", key, json])
    }

    /// `tabby tile [n]`: arranges the sessions' terminal windows in a grid.
    static func tile(_ count: Int?, completion: @escaping @MainActor (String) -> Void) {
        runCLI(["tile"] + (count.map { [String($0)] } ?? [])) { _, output in completion(output) }
    }

    /// Runs `<node> <tabby.js> <args…>` off the main thread, then refreshes the store and
    /// hands the combined stdout/stderr to `completion` on the main thread.
    static func runCLI(_ args: [String], completion: (@MainActor (Int32, String) -> Void)? = nil) {
        guard let cli = store?.snapshot.cli, !cli.cli.isEmpty else {
            completion?(-1, "tabby's CLI was not found. Run `tabby island` once from a terminal.")
            return
        }
        let node = cli.node
        let script = cli.cli
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [script] + args
            var environment = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = environment["PATH"].map { "\($0):\(extraPath)" } ?? extraPath
            environment["TABBY_SOURCE"] = "island"
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var status: Int32 = -1
            var output = ""
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                status = process.terminationStatus
                output = String(decoding: data, as: UTF8.self)
                if status != 0 {
                    NSLog("tabby island: `tabby %@` exited %d: %@", args.joined(separator: " "), status, output)
                }
            } catch {
                output = "Could not run tabby: \(error.localizedDescription)"
                NSLog("tabby island: could not run %@ %@: %@", node, script, error.localizedDescription)
            }
            let result = (status, output)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    store?.refresh()
                    completion?(result.0, result.1)
                }
            }
        }
    }

    /// The line of CLI output worth showing after `tile`: an Accessibility hint first,
    /// else anything that isn't the plain "Tiled …" success line.
    static func notice(fromTileOutput output: String) -> (text: String, accessibility: Bool)? {
        let lines = output
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let line = lines.first(where: { $0.localizedCaseInsensitiveContains("accessibility") }) {
            return (line, true)
        }
        if let line = lines.first(where: { !$0.hasPrefix("Tiled ") }) { return (line, false) }
        return nil
    }

    /// Splitting tabs into windows clicks a Terminal menu through System Events, which needs
    /// Accessibility for Tabby Island (and Automation of System Events and Terminal). Asking once
    /// adds the app to the list (off), so the user only has to flip its switch in the pane we open.
    ///
    /// Builds before 0.2.5 were signed by their own hash, so a permission granted to one build still
    /// shows as on in System Settings yet no longer applies after a rebuild. Clear the island's own
    /// stale entries first so macOS asks again, and the new grant sticks (the signature is stable now).
    static func openAccessibilitySettings() {
        if AXIsProcessTrusted() { return }
        let bundleId = Bundle.main.bundleIdentifier ?? "dev.tabby.island"
        for service in ["Accessibility", "AppleEvents"] {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", service, bundleId]
            reset.standardOutput = FileHandle.nullDevice
            reset.standardError = FileHandle.nullDevice
            if (try? reset.run()) != nil { reset.waitUntilExit() }
        }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Brings the session's terminal tab to the front.
    static func focus(_ session: IslandSession) {
        let term = (session.term ?? "").lowercased()
        if term.contains("iterm") {
            if let tty = session.tty {
                runAppleScript(iTermFocus, args: [tty])
            } else {
                open(bundleId: "com.googlecode.iterm2")
            }
        } else if term.isEmpty || term.contains("apple") || term == "terminal" {
            if let tty = session.tty {
                runAppleScript(terminalFocus, args: [tty])
            } else {
                open(bundleId: "com.apple.Terminal")
            }
        } else {
            open(bundleId: bundleId(forTerm: term) ?? "com.apple.Terminal")
        }
    }

    private static func bundleId(forTerm term: String) -> String? {
        if term.contains("ghostty") { return "com.mitchellh.ghostty" }
        if term.contains("vscode") || term.contains("cursor") {
            // Cursor also reports TERM_PROGRAM=vscode; prefer whichever is running.
            let cursor = "com.todesktop.230313mzl4w4u92", code = "com.microsoft.VSCode"
            if term.contains("cursor") { return cursor }
            if NSRunningApplication.runningApplications(withBundleIdentifier: code).isEmpty,
               !NSRunningApplication.runningApplications(withBundleIdentifier: cursor).isEmpty { return cursor }
            return code
        }
        if term.contains("warp") { return "dev.warp.Warp-Stable" }
        if term.contains("wezterm") { return "com.github.wez.wezterm" }
        if term.contains("kitty") { return "net.kovidgoyal.kitty" }
        if term.contains("alacritty") { return "org.alacritty" }
        if term.contains("tabby") { return "org.tabby" }
        return nil
    }

    private static func open(bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// osascript runs off the main thread so a first-time Automation prompt never freezes the island.
    private static func runAppleScript(_ source: String, args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            var arguments: [String] = []
            for line in source.split(separator: "\n", omittingEmptySubsequences: true) {
                arguments += ["-e", String(line)]
            }
            process.arguments = arguments + args
            process.standardOutput = FileHandle.nullDevice
            let stderr = Pipe()
            process.standardError = stderr
            do {
                try process.run()
                let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    NSLog("tabby island: focus failed: %@", String(decoding: errorOutput, as: UTF8.self))
                }
            } catch {
                NSLog("tabby island: osascript failed: %@", error.localizedDescription)
            }
        }
    }

    private static let terminalFocus = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is targetTTY then
                        if miniaturized of w then set miniaturized of w to false
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
            activate
        end tell
        return "not found"
    end run
    """

    private static let iTermFocus = """
    on run argv
        set targetTTY to item 1 of argv
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is targetTTY then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            activate
        end tell
        return "not found"
    end run
    """
}

// MARK: - Menus

@MainActor
final class MenuFactory: NSObject {
    static let shared = MenuFactory()

    private final class Handler {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        (sender.representedObject as? Handler)?.run()
    }

    func item(_ title: String, image: NSImage? = nil, symbol: String? = nil, checked: Bool = false,
              action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Handler(action)
        if let image {
            item.image = image
        } else if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        item.state = checked ? .on : .off
        return item
    }

    func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func submenu(_ title: String, symbol: String? = nil, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        item.submenu = menu
        return item
    }

    func sessionMenu(for session: IslandSession, store: SessionStore,
                     rename: @escaping @MainActor () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: session.title, action: nil, keyEquivalent: "")
        header.attributedTitle = MenuFactory.sessionTitle(session)
        header.image = Swatch.dot(session.dotHex ?? Palette.neutralHex)
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item("Focus Tab", symbol: "arrow.up.forward.app") { Actions.focus(session) })
        menu.addItem(item("Rename…", symbol: "pencil") { rename() })
        menu.addItem(submenu("Color", symbol: "paintbrush.pointed", menu: colorMenu(for: session, store: store)))
        menu.addItem(submenu("Theme", symbol: "paintpalette",
                             menu: themeMenu(store: store, current: session.theme ?? store.snapshot.globalThemeId) { id in
                                 Actions.setTheme(session, id: id)
                             }))

        menu.addItem(.separator())
        menu.addItem(item("Rename with AI", symbol: "sparkles") { Actions.renameWithAI(session) })
        menu.addItem(item("Reset Look", symbol: "arrow.counterclockwise") { Actions.resetLook(session) })
        return menu
    }

    /// The session theme's accents, as the dots the island shows.
    func colorMenu(for session: IslandSession, store: SessionStore) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for accent in store.accents(for: session) {
            menu.addItem(item(accent.key.capitalized, image: Swatch.dot(accent.dot),
                              checked: accent.key == session.accentKey) {
                Actions.setColor(session, key: accent.key)
            })
        }
        return menu
    }

    /// One submenu per theme group (Signature, Calm, Classic, Vivid, Light, High contrast).
    func themeMenu(store: SessionStore, current: String?, apply: @escaping @MainActor (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        let themes = store.snapshot.themes
        guard !themes.isEmpty else {
            menu.addItem(info("No themes yet — run `tabby install`"))
            return menu
        }
        let groups = store.snapshot.groups.isEmpty
            ? [ThemeGroup(id: "", name: "Themes")]
            : store.snapshot.groups
        let claude = ClaudeTheme.mode()
        for group in groups {
            let members = group.id.isEmpty ? themes : themes.filter { $0.group == group.id }
            guard !members.isEmpty else { continue }
            let submenu = NSMenu()
            for theme in members {
                let entry = item(theme.name, image: Swatch.theme(theme), checked: theme.id == current) {
                    apply(theme.id)
                }
                if !theme.blurb.isEmpty { entry.toolTip = theme.blurb }
                // Claude Code draws white text in its dark theme and black in its light one, so a
                // tabby theme of the other mode leaves Claude's own text unreadable.
                if theme.mode != claude {
                    let title = NSMutableAttributedString(string: theme.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                    title.append(NSAttributedString(string: "  needs Claude's \(theme.mode) theme", attributes: [
                        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                    entry.attributedTitle = title
                    entry.toolTip = "Claude Code is on its \(claude) theme, so its own text would be unreadable on \(theme.name). Type /theme in Claude to switch, or pick a \(claude) tabby theme."
                }
                submenu.addItem(entry)
            }
            let parent = self.submenu(group.name, menu: submenu)
            parent.state = members.contains { $0.id == current } ? .on : .off
            menu.addItem(parent)
        }
        return menu
    }

    /// "Tile all sessions (N)", then 2 · 3 · 4 · 6 · 8 windows.
    func tileMenu(sessionCount: Int, run: @escaping @MainActor (Int?) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let all = item("Tile All Sessions (\(sessionCount))", symbol: "square.grid.2x2") { run(nil) }
        all.isEnabled = sessionCount > 0
        menu.addItem(all)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Most recent sessions"))
        for count in [2, 3, 4, 6, 8] {
            menu.addItem(item("\(count) Windows") { run(count) })
        }
        return menu
    }

    func modeMenu(current: IslandMode, set: @escaping @MainActor (IslandMode) -> Void) -> NSMenu {
        let menu = NSMenu()
        for mode in IslandMode.allCases {
            let entry = item(mode.title, symbol: mode.symbol, checked: mode == current) { set(mode) }
            entry.toolTip = mode.help
            menu.addItem(entry)
        }
        return menu
    }

    /// "Title  project · status" with the secondary part dimmed.
    static func sessionTitle(_ session: IslandSession) -> NSAttributedString {
        let title = NSMutableAttributedString(string: session.title, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
        ])
        var secondary = "  \(session.project)"
        if session.status == .waiting { secondary += " · \(session.statusDetail.lowercased())" }
        title.append(NSAttributedString(string: secondary, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: session.status == .waiting ? Palette.waitingNS : NSColor.secondaryLabelColor,
        ]))
        return title
    }
}


/// Claude Code's own theme ("dark" unless /theme set something else in ~/.claude.json).
enum ClaudeTheme {
    static func mode() -> String {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let theme = json["theme"] as? String else { return "dark" }
        return theme.hasPrefix("light") ? "light" : "dark"
    }
}
