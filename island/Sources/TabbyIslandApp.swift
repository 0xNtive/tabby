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
            row["tty"] = session.tty
            row["term"] = session.term
            row["lastPrompt"] = session.lastPrompt
            row["summary"] = session.summary
            if let pct = session.contextPct { row["contextPct"] = (pct * 10).rounded() / 10 }
            row["usedTokens"] = session.context?.usedTokens
            row["windowSize"] = session.context?.windowSize
            return row
        }
        let output: [String: Any] = [
            "sessions": sessions,
            "themes": snapshot.themes.map { "\($0.id) (\($0.accents.count) accents)" },
            "globalTheme": snapshot.globalThemeId ?? NSNull(),
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

        setupStatusItem()
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
            let image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Tabby Island")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = "Tabby Island — your Claude Code sessions"
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
        let factory = MenuFactory.shared
        let sessions = store.listSessions
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No Claude sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(NSMenuItem.sectionHeader(title: "Claude sessions"))
            for session in sessions {
                let item = factory.item(session.title, image: Swatch.dot(session.accentHex ?? Palette.neutralHex)) {
                    Actions.focus(session)
                }
                item.attributedTitle = MenuFactory.sessionTitle(session)
                item.toolTip = [session.summary, session.lastPrompt.map { "“\($0)”" }, session.statusDetail]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(factory.item("Show Island", checked: island?.isShown ?? false) { [weak self] in
            self?.toggleIsland()
        })
        let themes = NSMenuItem(title: "Theme for All Tabs", action: nil, keyEquivalent: "")
        themes.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        themes.submenu = factory.themeMenu(store: store, current: store.snapshot.globalThemeId) { id in
            Actions.setThemeAll(id)
        }
        menu.addItem(themes)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tabby Island", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func toggleIsland() {
        guard let island else { return }
        if island.isShown { island.hide() } else { island.show() }
        UserDefaults.standard.set(island.isShown, forKey: "showIsland")
    }
}
