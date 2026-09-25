import AppKit

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

    /// Runs `<node> <tabby.js> <args…>` off the main thread, then refreshes the store.
    static func runCLI(_ args: [String]) {
        guard let cli = store?.snapshot.cli else { return }
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
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            let stderr = Pipe()
            process.standardError = stderr
            do {
                try process.run()
                let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    NSLog("tabby island: `tabby %@` exited %d: %@", args.joined(separator: " "),
                          process.terminationStatus, String(decoding: errorOutput, as: UTF8.self))
                }
            } catch {
                NSLog("tabby island: could not run %@ %@: %@", node, script, error.localizedDescription)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { store?.refresh() }
            }
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

// MARK: - Rename dialog

enum RenameResult {
    case rename(String)
    case auto
    case cancel
}

@MainActor
enum Dialogs {
    static func rename(current: String, project: String) -> RenameResult {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Rename tab"
        alert.informativeText = "Session in \(project). Leave it empty to let AI pick a name."
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.placeholderString = "Tab name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Let AI Name It")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? .auto : .rename(name)
        case .alertThirdButtonReturn:
            return .auto
        default:
            return .cancel
        }
    }
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

    func sessionMenu(for session: IslandSession, store: SessionStore,
                     rename: @escaping @MainActor () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: session.title, action: nil, keyEquivalent: "")
        header.attributedTitle = MenuFactory.sessionTitle(session)
        header.image = Swatch.dot(session.accentHex ?? Palette.neutralHex)
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(item("Focus Tab", symbol: "arrow.up.forward.app") { Actions.focus(session) })
        menu.addItem(item("Rename…", symbol: "pencil") { rename() })

        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colors.image = NSImage(systemSymbolName: "paintbrush.pointed", accessibilityDescription: nil)
        let colorMenu = NSMenu()
        for accent in store.accents(for: session) {
            colorMenu.addItem(item(accent.key.capitalized, image: Swatch.dot(accent.hex),
                                   checked: accent.key == session.accentKey) {
                Actions.setColor(session, key: accent.key)
            })
        }
        colors.submenu = colorMenu
        menu.addItem(colors)

        let themes = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themes.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        themes.submenu = themeMenu(store: store, current: session.theme ?? store.snapshot.globalThemeId) { id in
            Actions.setTheme(session, id: id)
        }
        menu.addItem(themes)

        menu.addItem(.separator())
        menu.addItem(item("Rename with AI", symbol: "sparkles") { Actions.renameWithAI(session) })
        menu.addItem(item("Reset Look", symbol: "arrow.counterclockwise") { Actions.resetLook(session) })
        return menu
    }

    func themeMenu(store: SessionStore, current: String?, apply: @escaping @MainActor (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        let themes = store.snapshot.themes
        guard !themes.isEmpty else {
            let empty = NSMenuItem(title: "No themes yet — run `tabby install`", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        let dark = themes.filter { $0.mode != "light" }
        let light = themes.filter { $0.mode == "light" }
        for (title, group) in [("Dark", dark), ("Light", light)] where !group.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: title))
            for theme in group {
                menu.addItem(item(theme.name, image: Swatch.theme(theme), checked: theme.id == current) {
                    apply(theme.id)
                })
            }
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
