import AppKit
import SwiftUI

/// `TabbyIsland --snapshot <dir>` renders the island to PNGs over a sample desktop, so the
/// design can be checked without Screen Recording permission:
///
/// - `island-*.png`: live sessions from ~/.claude (collapsed, each mode, a hovered row,
///   keyboard focus, announcements);
/// - `demo-*.png`: the same states with demo sessions that cover every status;
/// - `flat-*.png`: a display without a notch;
/// - `brand-*.png`: the menu-bar icon, the cat and the theme swatches.
@MainActor
enum Snapshotter {
    private struct State {
        let name: String
        let configure: (IslandUIState, [IslandSession]) -> Void
    }

    private static let states: [State] = [
        State(name: "collapsed") { _, _ in },
        State(name: "minimal") { ui, _ in ui.expanded = true; ui.mode = .minimal },
        State(name: "standard") { ui, _ in ui.expanded = true; ui.mode = .standard },
        State(name: "detailed") { ui, _ in ui.expanded = true; ui.mode = .detailed },
        State(name: "hover") { ui, list in
            ui.expanded = true
            ui.mode = .standard
            ui.hoveredRow = list.first?.id
        },
        State(name: "keyboard") { ui, list in
            ui.expanded = true
            ui.mode = .detailed
            ui.keyboard = true
            ui.hoveredRow = (list.count > 1 ? list[1] : list.first)?.id
        },
        State(name: "keyboard-minimal") { ui, list in
            ui.expanded = true
            ui.mode = .minimal
            ui.keyboard = true
            ui.hoveredRow = list.first?.id
        },
        State(name: "rename") { ui, list in
            ui.expanded = true
            ui.mode = .standard
            ui.keyboard = true
            ui.hoveredRow = list.first?.id
            ui.renaming = list.first?.id
            ui.renameText = list.first?.title ?? ""
        },
        State(name: "announce-done") { ui, list in
            ui.announcement = (list.first { $0.status.isYourTurn } ?? list.first).map(Announcement.done)
        },
        State(name: "announce-waiting") { ui, list in
            ui.announcement = (list.first { $0.status == .waiting } ?? list.last).map(Announcement.waiting)
        },
        State(name: "announce-info") { ui, _ in
            ui.announcement = .info("Allow Accessibility to split tabs", symbol: "hand.raised.fill",
                                    opensAccessibility: true)
        },
    ]

    static func run(directory: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let live = SessionStore(automation: false)
        live.refresh()
        let deadline = Date().addingTimeInterval(5)
        while !live.snapshot.loaded && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        Actions.store = live

        let (geometry, rect) = IslandGeometry.current()
        render(store: live, prefix: "island", geometry: geometry, size: rect.size, folder: folder, states: states)

        let demo = SessionStore(fixed: DemoData.snapshot(from: live.snapshot))
        render(store: demo, prefix: "demo", geometry: geometry, size: rect.size, folder: folder, states: states)

        var flat = geometry
        flat.hasNotch = false
        flat.notchWidth = 0
        flat.barHeight = 24
        render(store: demo, prefix: "flat", geometry: flat, size: rect.size, folder: folder,
               states: states.filter { ["collapsed", "standard", "announce-done"].contains($0.name) })

        renderBrand(folder: folder)
        renderSwatches(live.snapshot, folder: folder)
        renderSettings(store: demo, folder: folder)
        renderWatermarks(demo.snapshot, folder: folder)
        renderOnboarding(store: demo, folder: folder)
    }

    /// Each onboarding page (permissions mid-way: one allowed, one asking, one not asked yet), and
    /// the last page once everything is allowed.
    private static func renderOnboarding(store: SessionStore, folder: URL) {
        let island = IslandController(store: store, inert: true)
        let ready = PermissionCenter(accessibility: .allowed, automation: [.terminal: .allowed, .systemEvents: .allowed])
        let pages: [(OnboardingPage, PermissionCenter, String)] = [
            (.welcome, island.permissions, "welcome"), (.permissions, island.permissions, "permissions"),
            (.done, island.permissions, "done"), (.done, ready, "done-ready"),
        ]
        for (page, permissions, name) in pages {
            let model = OnboardingModel()
            model.page = page
            let host = NSHostingView(rootView: OnboardingView(model: model, permissions: permissions, state: island.settingsState,
                                                              island: island, finish: {}))
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            write(rep, to: folder.appendingPathComponent("onboarding-\(name).png"))
            window.close()
        }
    }

    // MARK: Settings and watermark

    /// Each Settings pane, in light and dark.
    private static func renderSettings(store: SessionStore, folder: URL) {
        let island = IslandController(store: store, inert: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for tab in SettingsTab.allCases {
                island.settingsState.tab = tab
                let host = NSHostingView(rootView: SettingsView(island: island, store: store, state: island.settingsState))
                host.frame = NSRect(x: 0, y: 0, width: 600, height: 640)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()
                host.display()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = appearance == .darkAqua ? "dark" : "light"
                write(rep, to: folder.appendingPathComponent("settings-\(tab.rawValue)-\(name).png"))
                window.close()
            }
        }
    }

    /// The watermark over mock terminal windows: demo sessions in several sizes and positions.
    private static func renderWatermarks(_ snapshot: StoreSnapshot, folder: URL) {
        let cases: [(WatermarkSize, WatermarkPosition, WatermarkColor, CGSize)] = [
            (.medium, .center, .session, CGSize(width: 760, height: 460)),
            (.large, .center, .session, CGSize(width: 760, height: 460)),
            (.small, .top, .session, CGSize(width: 760, height: 460)),
            (.medium, .bottom, .neutral, CGSize(width: 760, height: 460)),
            (.medium, .center, .session, CGSize(width: 480, height: 620)),
            (.medium, .center, .session, CGSize(width: 1400, height: 380)),
        ]
        for (index, item) in cases.enumerated() {
            let session = snapshot.sessions[index % max(1, snapshot.sessions.count)]
            var settings = WatermarkSettings()
            settings.size = item.0
            settings.position = item.1
            settings.color = item.2
            let theme = snapshot.themes.first { $0.id == (session.theme ?? snapshot.globalThemeId) }
            let view = TerminalMockView(frame: NSRect(origin: .zero, size: item.3))
            view.background = NSColor(hexString: theme?.bg) ?? .black
            view.foreground = NSColor(hexString: theme?.fg) ?? .white
            view.watermark.text = session.title
            view.watermark.tint = settings.tint(for: session, themes: snapshot.themes, globalTheme: snapshot.globalThemeId)
            view.watermark.settings = settings
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.layout()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = "watermark-\(index + 1)-\(item.0.rawValue)-\(item.1.rawValue)-\(item.2.rawValue).png"
            write(rep, to: folder.appendingPathComponent(name))
            window.close()
        }
    }

    // MARK: Island states

    private static func render(store: SessionStore, prefix: String, geometry: IslandGeometry, size: CGSize,
                               folder: URL, states: [State]) {
        var panelSize = geometry.panelSize
        panelSize.width = size.width
        for state in states {
            let ui = IslandUIState()
            ui.staticRender = true
            ui.reduceMotion = false
            var sized = geometry
            sized.panelSize = panelSize
            ui.geometry = sized
            ui.mode = store.snapshot.config.mode
            state.configure(ui, store.listSessions)
            var islandFrame = CGRect.zero
            var actions = IslandActions.inert
            actions.islandFrame = { islandFrame = $0 }
            let host = NSHostingView(rootView: IslandRootView(store: store, ui: ui, actions: actions))
            host.frame = NSRect(origin: .zero, size: panelSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let composed = composite(rep, size: panelSize, barHeight: sized.barHeight)
            // Crop to the island plus a margin, so the PNGs stay easy to inspect.
            var crop = CGRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)
            if !islandFrame.isEmpty {
                let margin: CGFloat = 36
                crop = CGRect(x: max(0, islandFrame.minX - margin), y: 0,
                              width: min(panelSize.width, islandFrame.width + 2 * margin),
                              height: min(panelSize.height, islandFrame.maxY + margin))
            }
            write(cropped(composed, to: crop, size: panelSize),
                  to: folder.appendingPathComponent("\(prefix)-\(state.name).png"))
            window.close()
        }
    }

    /// Draws the rendered panel over a gradient "wallpaper" with a menu-bar strip, or, with
    /// `TABBY_SNAPSHOT_BACKDROP=none` (renders for the website), on a transparent background.
    private static func composite(_ island: NSBitmapImageRep, size: CGSize, barHeight: CGFloat) -> NSBitmapImageRep {
        guard let out = bitmap(pixelsWide: island.pixelsWide, pixelsHigh: island.pixelsHigh, size: size) else { return island }
        let bare = ProcessInfo.processInfo.environment["TABBY_SNAPSHOT_BACKDROP"] == "none"
        draw(into: out) {
            let bounds = NSRect(origin: .zero, size: size)
            if bare {
                island.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                return
            }
            NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.25, blue: 0.40, alpha: 1),
                                NSColor(srgbRed: 0.40, green: 0.29, blue: 0.45, alpha: 1)])?.draw(in: bounds, angle: -60)
            NSColor(white: 1, alpha: 0.16).setFill()
            NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight).fill()
            island.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        return out
    }

    /// `rect` in points, top-left origin.
    private static func cropped(_ rep: NSBitmapImageRep, to rect: CGRect, size: CGSize) -> NSBitmapImageRep {
        let scale = CGFloat(rep.pixelsWide) / size.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        guard let image = rep.cgImage?.cropping(to: pixels.integral) else { return rep }
        let out = NSBitmapImageRep(cgImage: image)
        out.size = rect.size
        return out
    }

    // MARK: Brand

    private static func renderBrand(folder: URL) {
        // Menu-bar icon: actual size on a light and a dark bar, and 8× for detail.
        let icon = Brand.statusIcon()
        let barSize = CGSize(width: 220, height: 64)
        if let rep = bitmap(pixelsWide: Int(barSize.width * 2), pixelsHigh: Int(barSize.height * 2), size: barSize) {
            draw(into: rep) {
                for (index, dark) in [false, true].enumerated() {
                    let bar = NSRect(x: 0, y: CGFloat(index) * 32, width: 70, height: 32)
                    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    bar.fill()
                    tinted(icon, dark ? .white : .black)
                        .draw(in: NSRect(x: 26, y: bar.minY + 7, width: 18, height: 18))
                }
                NSColor(white: 0.5, alpha: 1).setFill()
                NSRect(x: 76, y: 0, width: 144, height: 64).fill()
                tinted(icon, .black).draw(in: NSRect(x: 118, y: 2, width: 60, height: 60))
            }
            write(rep, to: folder.appendingPathComponent("brand-statusitem.png"))
        }

        // Footer cat at 18 pt (as shipped), 32 pt and 96 pt, on the island's black.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 110))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        var x: CGFloat = 12
        for side: CGFloat in [18, 32, 96] {
            let cat = CatMarkView(frame: NSRect(x: x, y: (110 - side) / 2, width: side, height: side))
            container.addSubview(cat)
            x += side + 14
        }
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        container.subviews.forEach { $0.layout() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
            container.cacheDisplay(in: container.bounds, to: rep)
            write(rep, to: folder.appendingPathComponent("brand-cat.png"))
        }
        window.close()
    }

    /// Every theme's menu swatch, grouped the way the Theme menus are.
    private static func renderSwatches(_ snapshot: StoreSnapshot, folder: URL) {
        let groups = snapshot.groups.isEmpty ? [ThemeGroup(id: "", name: "Themes")] : snapshot.groups
        let columns = 4
        let cell = CGSize(width: 170, height: 22)
        var rows: [(title: String?, themes: [ThemeInfo])] = []
        for group in groups {
            let members = group.id.isEmpty ? snapshot.themes : snapshot.themes.filter { $0.group == group.id }
            guard !members.isEmpty else { continue }
            rows.append((group.name, []))
            stride(from: 0, to: members.count, by: columns).forEach {
                rows.append((nil, Array(members[$0..<min($0 + columns, members.count)])))
            }
        }
        let size = CGSize(width: cell.width * CGFloat(columns) + 20, height: CGFloat(rows.count) * cell.height + 20)
        guard let rep = bitmap(pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), size: size) else { return }
        draw(into: rep) {
            NSColor(white: 0.16, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            var y = size.height - 10 - cell.height
            for row in rows {
                if let title = row.title {
                    (title as NSString).draw(at: NSPoint(x: 10, y: y + 4), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(white: 0.6, alpha: 1),
                    ])
                }
                for (index, theme) in row.themes.enumerated() {
                    let origin = NSPoint(x: 10 + CGFloat(index) * cell.width, y: y + 4)
                    Swatch.theme(theme).draw(in: NSRect(x: origin.x, y: origin.y, width: 46, height: 14))
                    (theme.name as NSString).draw(at: NSPoint(x: origin.x + 52, y: origin.y), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.9, alpha: 1),
                    ])
                }
                y -= cell.height
            }
        }
        write(rep, to: folder.appendingPathComponent("brand-swatches.png"))
    }

    // MARK: Drawing helpers

    private static func bitmap(pixelsWide: Int, pixelsHigh: Int, size: CGSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func draw(into rep: NSBitmapImageRep, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func write(_ rep: NSBitmapImageRep, to file: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: file)
        print(file.path)
    }
}

// MARK: - Demo sessions (every status, notes, summaries)

enum DemoData {
    static func snapshot(from live: StoreSnapshot) -> StoreSnapshot {
        var snapshot = live
        snapshot.loaded = true
        let theme = live.themes.first { $0.id == (live.globalThemeId ?? live.defaultThemeId) }
        func look(_ key: String) -> (String, String) {
            if let accent = theme?.accents.first(where: { $0.key == key }) { return (accent.hex, accent.dot) }
            let accent = Palette.fallbackAccents.first { $0.key == key } ?? Palette.fallbackAccents[0]
            return (accent.hex, accent.dot)
        }
        let now = Date().timeIntervalSince1970 * 1000
        func ago(_ minutes: Double) -> Double { now - minutes * 60_000 }
        func session(_ n: Int, _ title: String, _ project: String, _ key: String, _ status: SessionStatus,
                     waitingFor: String? = nil, used: Int?, window: Int = 1_000_000, cost: Double?,
                     model: String = "Opus 5.5", summary: String? = nil, note: String? = nil, prompt: String? = nil,
                     started: Double, activity: Double) -> IslandSession {
            let (hex, dot) = look(key)
            let context = used.map { ContextUsage(usedPct: Double($0) / Double(window) * 100, usedTokens: $0,
                                                  windowSize: window, costUsd: cost, model: model, at: now) }
            return IslandSession(id: "demo-\(n)", sessionId: "demo-\(n)", pid: 90_000 + n, cwd: "/Users/you/\(project)",
                                 project: project, registryName: nil, title: title, titleSource: "ai",
                                 summary: summary, note: note, theme: theme?.id, accentKey: key, accentHex: hex,
                                 dotHex: dot, cursorHex: hex, status: status, waitingFor: waitingFor,
                                 lastPrompt: prompt, context: context, model: model, tty: nil, term: "apple-terminal",
                                 startedAt: ago(started), activityAt: ago(activity), hasRecord: true)
        }
        var sessions = [
            session(1, "Refactor auth middleware", "api", "blue", .waiting, waitingFor: "permission",
                    used: 342_000, cost: 1.42,
                    summary: "Splitting session handling out of the auth middleware; the new tests pass locally.",
                    prompt: "can you also move the token refresh into its own module?", started: 95, activity: 2),
            session(2, "Migrate billing to Stripe v3", "billing", "orange", .busy, used: 452_000, cost: 3.2,
                    summary: "Porting webhooks and invoices to the v3 API. 14 of 22 handlers are done and green.",
                    note: "Ship behind the billing_v3 flag", prompt: "keep the old webhook route alive until Friday",
                    started: 180, activity: 4),
            session(3, "Fix flaky checkout e2e test", "web", "green", .idle, used: 36_000, window: 200_000, cost: 0.61,
                    model: "Sonnet 5",
                    summary: "Found a race in the checkout spec and now wait for the cart request before paying.",
                    prompt: "run it 20 times to make sure it's stable", started: 60, activity: 12),
            session(4, "Write the 2.0 release notes", "docs", "purple", .busy, used: 186_000, window: 200_000, cost: 5.08,
                    model: "Sonnet 5", prompt: "mention the new keyboard shortcuts first", started: 240, activity: 1),
            session(5, "Benchmark the tokenizer", "tok", "teal", .error, used: nil, cost: nil,
                    summary: "The benchmark crashed on the 1 GB fixture (out of memory).", started: 30, activity: 6),
        ]
        // Working sessions: one follows Claude's task list, one its usual turn length.
        sessions[1].turnStartedAt = ago(8)
        sessions[1].tasks = TaskProgress(total: 5, done: 2, active: 1, current: "Porting the invoice webhooks to v3")
        sessions[1].typicalTurn = 360
        sessions[3].turnStartedAt = ago(2)
        sessions[3].typicalTurn = 360
        sessions[0].turnStartedAt = ago(4)
        snapshot.sessions = sessions
        return snapshot
    }
}
