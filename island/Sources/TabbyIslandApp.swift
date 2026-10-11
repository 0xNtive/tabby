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
            row["typicalTurn"] = session.typicalTurn.map { ($0 * 10).rounded() / 10 }
            row["workElapsed"] = session.workElapsed(now: Date()).map { $0.rounded() }
            row["progress"] = session.progress(now: Date()).map { guess in
                "\(guess.fraction.map { "\(Int(($0 * 100).rounded()))% · " } ?? "")\(guess.caption)"
            }
            row["tasks"] = session.tasks.map { "\($0.done)/\($0.total) done\($0.current.map { ", now: \($0)" } ?? "")" }
            row["activity"] = session.activity
            row["reply"] = session.reply.map { ["lead": $0.lead, "ask": $0.ask ?? NSNull(), "lines": $0.lines] as [String: Any] }
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
    /// The status menu (rebuilt each time it opens). At the notch a click opens it; in menu-bar
    /// mode a click drops the card down and a right-click (or ⌃-click) opens it.
    private let statusMenu = NSMenu()
    private var place: IslandPlace = .notch
    /// What the status item shows now, so an unchanged store refresh doesn't redraw it.
    private var badgeKey = ""
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
        // "Show the island" off (before `islandPlace`) left only the menu-bar icon: that's
        // menu-bar mode now, until a place is chosen.
        IslandPlace.legacy = UserDefaults.standard.bool(forKey: "showIsland") ? .notch : .menubar
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        IslandReport.write(["quitByUser": false, "notch": (screen?.safeAreaInsets.top ?? 0) > 0,
                            "onboardingDone": UserDefaults.standard.bool(forKey: "onboardingDone"),
                            "macOS": ProcessInfo.processInfo.operatingSystemVersionString])
        Actions.store = store
        store.start()

        setupStatusItem()
        let island = IslandController(store: store)
        self.island = island
        island.statusItemFrame = { [weak self] in self?.statusItemFrame }
        island.onPlaceChange = { [weak self] place in self?.applyPlace(place) }
        island.onCardChange = { [weak self] open in self?.statusItem?.button?.highlight(open) }
        island.show()
        // The setup window: once on first launch, and whenever the installer or
        // `tabby island onboarding` asks (`--allow-accessibility` starts at the permissions).
        let arguments = CommandLine.arguments
        let asked = arguments.contains("--onboarding") || arguments.contains("--allow-accessibility")
        if asked || !UserDefaults.standard.bool(forKey: "onboardingDone") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                island.showOnboarding(arguments.contains("--allow-accessibility") ? .permissions : .welcome, activate: asked)
            }
        }

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

    /// macOS keeps where the item sits under this name (and where you ⌘-drag it).
    private static let autosaveName = "tabby"
    private static var positionKey: String { "NSStatusItem Preferred Position \(autosaveName)" }
    /// Points from the right edge of the screen: among the system's own items, which stay
    /// clear of the notch however full the menu bar gets.
    private static let revealedPosition = 250

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.image = Brand.statusIcon()
            button.imagePosition = .imageLeading
            button.toolTip = "tabby — your Claude Code sessions"
            button.setAccessibilityLabel("tabby")
            // Only called while no menu is attached (menu-bar mode): on press, like a menu.
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        statusMenu.delegate = self
        item.menu = statusMenu
        statusItem = item
    }

    /// The status item's frame on screen: menu-bar mode hangs the card from it.
    private var statusItemFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func applyPlace(_ place: IslandPlace) {
        self.place = place
        configureStatusItem()
        // Once the menu bar has laid the item out.
        if place == .menubar {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated { self?.revealStatusItem() }
            }
        }
    }

    private func configureStatusItem() {
        guard let item = statusItem else { return }
        item.menu = place == .notch ? statusMenu : nil
        if place == .menubar { item.isVisible = true }
        item.button?.toolTip = place == .notch
            ? "tabby — your Claude Code sessions"
            : "tabby — click for your Claude Code sessions, right-click for the menu"
        item.button?.setAccessibilityHelp(place == .notch ? nil : "Click for your sessions, right-click for the menu")
        badgeKey = ""
        updateStatusBadge(store.snapshot)
    }

    /// On a notched Mac whose menu bar is full, the items that don't fit hide behind the notch,
    /// and a new item (tabby's) is the first to go. In menu-bar mode the icon is all there is, so
    /// it moves next to the system's items; if even that is behind the notch, the island says so.
    private func revealStatusItem(retried: Bool = false) {
        guard place == .menubar, behindNotch else { return }
        guard !retried else {
            island?.enqueue(.info("tabby's icon is behind the notch: make room in the menu bar, or press \(toggleShortcut)",
                                  symbol: "menubar.rectangle", topic: "statusitem"), force: true)
            return
        }
        Debug.log("status item behind the notch at \(statusItemFrame.map(NSStringFromRect) ?? "-"); moving it")
        // Removing the item forgets where it was, so the new spot is written after that and
        // before the new item reads it.
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        UserDefaults.standard.set(Self.revealedPosition, forKey: Self.positionKey)
        setupStatusItem()
        configureStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.revealStatusItem(retried: true) }
        }
    }

    /// The item sits (at least partly) where the camera notch is, so nobody can see or click it.
    private var behindNotch: Bool {
        guard let frame = statusItemFrame,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }),
              screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return false }
        let notch = (screen.frame.minX + left.width)...(screen.frame.maxX - right.width)
        return frame.maxX > notch.lowerBound && frame.minX < notch.upperBound
    }

    private var toggleShortcut: String {
        guard let island, island.config.hotkeys, let combo = island.config.shortcuts[.toggle] else { return "its shortcut" }
        return ShortcutAction.toggle.display(combo)
    }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true
        guard place == .menubar, !wantsMenu else {
            island?.closeCard()
            // After this press is handled: the native way, highlighted under the item.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.showStatusMenu() }
            }
            return
        }
        island?.toggleCard()
    }

    private func showStatusMenu() {
        guard let item = statusItem, let button = item.button else { return }
        item.menu = statusMenu
        button.performClick(nil)
        item.menu = place == .notch ? statusMenu : nil
    }

    /// The waiting count, and in menu-bar mode a dot per session too (the island's dots), so the
    /// state shows without the island.
    private func updateStatusBadge(_ snapshot: StoreSnapshot) {
        guard let button = statusItem?.button else { return }
        let waiting = snapshot.sessions.filter { $0.status == .waiting }.count
        let dots = place == .menubar ? StatusDots.dots(snapshot.sessions) : []
        let key = "\(waiting)|" + dots.map { "\($0.hex ?? "")\($0.status.rawValue)" }.joined(separator: ",")
            + "|\(snapshot.sessions.count)"
        guard key != badgeKey else { return }
        badgeKey = key
        button.attributedTitle = StatusDots.title(dots: dots, total: snapshot.sessions.count, waiting: waiting)
        button.setAccessibilityValue(StatusDots.summary(snapshot.sessions))
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
        let atNotch = factory.item("Island at the Notch", checked: config.place == .notch) { [weak island] in
            island?.setPlace(.notch)
        }
        atNotch.toolTip = "Hover the top of the screen for every session"
        menu.addItem(atNotch)
        let inMenuBar = factory.item("Menu Bar Only", checked: config.place == .menubar) { [weak island] in
            island?.setPlace(.menubar)
        }
        inMenuBar.toolTip = "No island: click this icon for every session, right-click for this menu"
        menu.addItem(inMenuBar)
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
        let focus = factory.item("Focus Mode", checked: config.focusMode) { [weak island] in
            island?.setFocusMode(!config.focusMode)
        }
        focus.toolTip = "While Claude works, Terminal windows you're not in show only their topic and what's running"
        menu.addItem(focus)
        menu.addItem(.separator())
        let launch = factory.item("New Session…", symbol: "plus") { [weak island] in island?.showQuickLaunch() }
        if config.hotkeys { shortcut(launch, config.shortcuts[.launch]) }
        menu.addItem(launch)
        menu.addItem(factory.submenu("Tile Windows", symbol: "rectangle.split.2x2",
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
        menu.addItem(factory.item("Setup & Permissions…", symbol: "checkmark.shield") { [weak island] in
            island?.showOnboarding(.permissions, activate: true)
        })
        let updates = island.updates
        if case .updating = updates.phase {
            menu.addItem(factory.info("Updating tabby…"))
        } else if updates.info.available, let latest = updates.info.latest {
            menu.addItem(factory.item("Update to tabby \(latest)…", symbol: "arrow.down.circle") { updates.update() })
        } else {
            menu.addItem(factory.item("Check for Updates…", symbol: "arrow.triangle.2.circlepath") { updates.check(manual: true) })
        }
        menu.addItem(factory.item("About tabby", symbol: "info.circle") { [weak self] in self?.showAbout() })
        let quit = NSMenuItem(title: "Quit Tabby Island", action: #selector(quitByUser), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Quit from the menu: new Claude sessions leave it closed until `tabby island` or next login.
    @objc private func quitByUser() {
        IslandReport.write(["quitByUser": true])
        NSApp.terminate(nil)
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

    /// Debug: at the notch ↔ in the menu bar.
    private func toggleIsland() {
        guard let island else { return }
        island.setPlace(island.config.place == .notch ? .menubar : .notch)
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
            .applicationVersion: "\(Brand.version) beta",
            .version: "",
            .credits: credits,
        ])
    }
}

// MARK: - The status item's dots (menu-bar mode)

/// One dot per session in the menu bar, in start order like the island's: working rings in its
/// own color, needs-you amber, an error red, your turn dimmed. A still image (no loop, no CPU).
enum StatusDots {
    struct Dot: Equatable {
        let hex: String?
        let status: SessionStatus
    }

    static let limit = 6

    static func dots(_ sessions: [IslandSession]) -> [Dot] {
        sessions
            .sorted { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.id < $1.id }
            .prefix(limit)
            .map { Dot(hex: $0.dotHex, status: $0.status) }
    }

    /// " ●●◉ 2": the dots, "+3" past six, and the waiting count in amber.
    static func title(dots: [Dot], total: Int, waiting: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !dots.isEmpty {
            let attachment = NSTextAttachment()
            let image = image(dots)
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            out.append(NSAttributedString(string: " "))
            out.append(NSAttributedString(attachment: attachment))
            if total > dots.count {
                out.append(NSAttributedString(string: " +\(total - dots.count)", attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
        }
        if waiting > 0 {
            out.append(NSAttributedString(string: " \(waiting)", attributes: [
                .foregroundColor: Palette.waitingNS,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            ]))
        }
        return out
    }

    static func image(_ dots: [Dot]) -> NSImage {
        let cell: CGFloat = 10
        let height: CGFloat = 12
        let size = NSSize(width: max(1, CGFloat(dots.count) * cell - 1), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, dot) in dots.enumerated() {
                let center = NSPoint(x: CGFloat(index) * cell + 4.5, y: height / 2)
                let base = NSColor(hexString: dot.hex ?? Palette.neutralHex) ?? .gray
                let fill: NSColor
                let ring: NSColor?
                switch dot.status {
                case .busy: (fill, ring) = (base, base.withAlphaComponent(0.6))
                case .waiting: (fill, ring) = (Palette.waitingNS, Palette.waitingNS.withAlphaComponent(0.6))
                case .error: (fill, ring) = (Palette.dangerNS, Palette.dangerNS.withAlphaComponent(0.6))
                default: (fill, ring) = (base.withAlphaComponent(0.5), nil)
                }
                if let ring {
                    let path = NSBezierPath(ovalIn: NSRect(x: center.x - 4.25, y: center.y - 4.25, width: 8.5, height: 8.5))
                    path.lineWidth = 1.1
                    ring.setStroke()
                    path.stroke()
                }
                let radius: CGFloat = ring == nil ? 3 : 2.4
                fill.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// For VoiceOver: "3 sessions: 1 needs you, 1 working".
    static func summary(_ sessions: [IslandSession]) -> String {
        guard !sessions.isEmpty else { return "No Claude sessions" }
        var parts: [String] = []
        let busy = sessions.filter { $0.status == .busy }.count
        let waiting = sessions.filter { $0.status == .waiting }.count
        let errors = sessions.filter { $0.status == .error }.count
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if errors > 0 { parts.append("\(errors) with an error") }
        if busy > 0 { parts.append("\(busy) working") }
        let count = "\(sessions.count) session\(sessions.count == 1 ? "" : "s")"
        return parts.isEmpty ? count : "\(count): " + parts.joined(separator: ", ")
    }
}
