import AppKit
import Combine

@main
struct TabbyIslandApp {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        let automation = !arguments.contains("--no-automation")
        if arguments.contains("--dump") {
            dump(automation: automation)
            return
        }
        if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
            Snapshotter.run(directory: arguments[i + 1])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(automation: automation)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// `TabbyIsland --dump`: print what the island would show, as JSON, and exit.
    private static func dump(automation: Bool) {
        let loader = SnapshotLoader(automation: automation)
        var snapshot = loader.load()
        if automation {
            // Give the background tab-title read one round to land.
            Thread.sleep(forTimeInterval: 3.2)
            snapshot = loader.load()
        }
        let sessions: [[String: Any]] = snapshot.sessions.map { session in
            var row: [String: Any] = [
                "id": session.id, "pid": session.pid, "title": session.title, "project": session.project,
                "status": session.status.rawValue, "statusDetail": session.statusDetail,
                "hasRecord": session.hasRecord, "startedAt": session.startedAt,
            ]
            row["model"] = session.model
            row["accent"] = session.accentHex
            row["dot"] = session.dotHex
            row["tty"] = session.tty
            row["term"] = session.term
            row["windowId"] = session.windowId
            row["lastPrompt"] = session.lastPrompt
            row["summary"] = session.summary
            if let pct = session.contextPct { row["contextPct"] = (pct * 10).rounded() / 10 }
            row["usedTokens"] = session.context?.usedTokens
            row["windowSize"] = session.context?.windowSize
            return row
        }
        let output: [String: Any] = [
            "sessions": sessions,
            "themes": snapshot.themes.map { "\($0.id) [\($0.group)] (\($0.accents.count) accents)" },
            "groups": snapshot.groups.map { "\($0.id): \($0.name)" },
            "globalTheme": snapshot.globalThemeId ?? NSNull(),
            "config": ["islandMode": snapshot.config.mode.rawValue, "islandAnnounce": snapshot.config.announce,
                       "islandHotkeys": snapshot.config.hotkeys,
                       "islandShortcuts": ShortcutAction.allCases.map { "\($0.rawValue)=\(snapshot.config.shortcuts[$0]?.spec ?? "none")" },
                       "watermark": [
                           "enabled": snapshot.config.watermark.enabled, "opacity": snapshot.config.watermark.opacity,
                           "size": snapshot.config.watermark.size.rawValue, "color": snapshot.config.watermark.color.rawValue,
                           "position": snapshot.config.watermark.position.rawValue,
                       ] as [String: Any]],
            "terminalWindows": snapshot.terminalWindowIds.sorted(),
            "automationDenied": snapshot.automationDenied,
            "cli": ["node": snapshot.cli.node, "cli": snapshot.cli.cli],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: SessionStore
    private var island: IslandController?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    init(automation: Bool) {
        store = SessionStore(automation: automation)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        UserDefaults.standard.register(defaults: ["showIsland": true])
        Actions.store = store
        store.start()

        let island = IslandController(store: store)
        self.island = island
        if UserDefaults.standard.bool(forKey: "showIsland") { island.show() }
        // `tabby island accessibility` (and the installer): ask for the permission tiling needs.
        if CommandLine.arguments.contains("--allow-accessibility") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Actions.openAccessibilitySettings() }
        }

        setupStatusItem()
        if Debug.enabled {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("dev.tabby.island.debug"), object: nil, queue: .main
            ) { [weak self] note in
                let command = note.object as? String
                MainActor.assumeIsolated {
                    if command == "menu" { self?.dumpMenu() }
                    if command == "about" { self?.showAbout() }
                    if command == "toggle-island" { self?.toggleIsland() }
                }
            }
        }
        store.$snapshot
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated { self?.updateStatusBadge(snapshot) }
            }
            .store(in: &cancellables)
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Brand.statusIcon()
            button.imagePosition = .imageLeading
            button.toolTip = "tabby — your Claude Code sessions"
            button.setAccessibilityLabel("tabby")
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func updateStatusBadge(_ snapshot: StoreSnapshot) {
        guard let button = statusItem?.button else { return }
        let waiting = snapshot.sessions.filter { $0.status == .waiting }.count
        if waiting > 0 {
            button.attributedTitle = NSAttributedString(string: " \(waiting)", attributes: [
                .foregroundColor: Palette.waitingNS,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let island else { return }
        let factory = MenuFactory.shared
        let config = island.config
        let sessions = store.listSessions
        if sessions.isEmpty {
            menu.addItem(factory.info("No Claude sessions"))
        } else {
            menu.addItem(NSMenuItem.sectionHeader(title: "Claude sessions"))
            for (index, session) in sessions.enumerated() {
                let item = factory.item(session.title, image: Swatch.dot(session.dotHex ?? Palette.neutralHex)) {
                    Actions.focus(session)
                }
                item.attributedTitle = MenuFactory.sessionTitle(session)
                item.toolTip = [session.summary, session.lastPrompt.map { "“\($0)”" }, session.statusDetail]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                if config.hotkeys, index < 9, let jump = config.shortcuts[.jump] {
                    shortcut(item, KeyCombo(KeyNames.jumpDigits[index], jump.modifiers))
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(factory.item("Show Island", checked: island.isShown) { [weak self] in
            self?.toggleIsland()
        })
        menu.addItem(factory.submenu("Mode", symbol: config.mode.symbol,
                                     menu: factory.modeMenu(current: config.mode) { [weak island] mode in
                                         island?.setMode(mode)
                                     }))
        let announce = factory.item("Show Announcements", checked: config.announce) { [weak island] in
            island?.setAnnounce(!config.announce)
        }
        announce.toolTip = "“✓ … is done” and “… needs you” in the island while it's collapsed"
        menu.addItem(announce)
        let watermark = factory.item("Show Watermark", checked: config.watermark.enabled) { [weak island] in
            island?.toggleWatermark()
        }
        watermark.toolTip = "Each session's topic in large, faint letters over its Terminal window"
        if config.hotkeys { shortcut(watermark, config.shortcuts[.watermark]) }
        menu.addItem(watermark)
        menu.addItem(.separator())
        menu.addItem(factory.submenu("Tile Windows", symbol: "square.grid.2x2",
                                     menu: factory.tileMenu(sessionCount: sessions.count) { [weak island] count in
                                         island?.tile(count)
                                     }))
        menu.addItem(factory.submenu("Theme for All Tabs", symbol: "paintpalette",
                                     menu: factory.themeMenu(store: store, current: store.snapshot.globalThemeId) { id in
                                         Actions.setThemeAll(id)
                                     }))
        menu.addItem(factory.submenu("Keyboard Shortcuts", symbol: "keyboard", menu: shortcutsMenu(config)))
        menu.addItem(.separator())
        let settings = factory.item("Settings…", symbol: "gearshape") { [weak island] in island?.openSettings() }
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)
        menu.addItem(factory.item("About tabby", symbol: "info.circle") { [weak self] in self?.showAbout() })
        menu.addItem(NSMenuItem(title: "Quit Tabby Island", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    /// Shows a shortcut on a menu item (only while the menu is open does it act as one).
    private func shortcut(_ item: NSMenuItem, _ combo: KeyCombo?) {
        guard let combo, let key = combo.menuKey else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = combo.modifiers.eventFlags
    }

    private func shortcutsMenu(_ config: IslandConfig) -> NSMenu {
        let factory = MenuFactory.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        let on = config.hotkeys
        let taken = HotkeyCenter.shared.unavailable
        for action in ShortcutAction.allCases where action != .jump {
            let combo = config.shortcuts[action]
            let inUse = combo.map { taken.contains($0) } ?? false
            let item = factory.item(inUse ? "\(action.menuTitle) (shortcut in use by another app)" : action.menuTitle) {
                [weak island] in island?.perform(action)
            }
            if on { shortcut(item, combo) }
            menu.addItem(item)
        }
        if let jump = config.shortcuts[.jump] {
            menu.addItem(factory.info("Jump to Session 1–9   \(ShortcutAction.jump.display(jump))"))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "In the island"))
        for line in ["↑ ↓  select   ↩  open   1–9  jump", "R  rename   C  color   T  theme",
                     "M  mode   G  tile   W  watermark", ",  settings   esc  close"] {
            menu.addItem(factory.info(line))
        }
        menu.addItem(.separator())
        menu.addItem(factory.item("Enable Global Shortcuts", checked: on) { [weak island] in
            island?.setHotkeys(!on)
        })
        menu.addItem(factory.item("Customize Shortcuts…") { [weak island] in island?.openSettings(.shortcuts) })
        return menu
    }

    /// Debug: the status menu as text (it can't be screenshotted without Screen Recording).
    private func dumpMenu() {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        var lines: [String] = []
        func walk(_ menu: NSMenu, _ depth: Int) {
            for item in menu.items {
                if item.isSeparatorItem { lines.append(String(repeating: "  ", count: depth) + "—"); continue }
                var line = String(repeating: "  ", count: depth) + (item.state == .on ? "✓ " : "") + item.title
                if !item.keyEquivalent.isEmpty {
                    let mods = item.keyEquivalentModifierMask
                    line += "  [\(mods.contains(.control) ? "⌃" : "")\(mods.contains(.option) ? "⌥" : "")\(mods.contains(.command) ? "⌘" : "")\(item.keyEquivalent == " " ? "Space" : item.keyEquivalent.uppercased())]"
                }
                if !item.isEnabled { line += "  (disabled)" }
                if item.image != nil { line += "  ◧" }
                lines.append(line)
                if let submenu = item.submenu, depth < 1 || submenu.items.count < 30 { walk(submenu, depth + 1) }
            }
        }
        walk(menu, 0)
        Debug.log("status menu:\n" + lines.joined(separator: "\n"))
    }

    private func toggleIsland() {
        guard let island else { return }
        island.setShown(!island.isShown)
    }

    private func showAbout() {
        let credits = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        credits.append(NSAttributedString(string: "Tabby Island · every Claude Code tab, at a glance.\n", attributes: body))
        var link = body
        link[.link] = Brand.github
        credits.append(NSAttributedString(string: "GitHub", attributes: link))
        credits.append(NSAttributedString(string: "  ·  ", attributes: body))
        link[.link] = Brand.website
        credits.append(NSAttributedString(string: "claude-tabby.vercel.app", attributes: link))

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "tabby",
            .applicationVersion: Brand.version,
            .version: "",
            .credits: credits,
        ])
    }
}
