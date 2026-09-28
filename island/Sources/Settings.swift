import AppKit
import SwiftUI

// MARK: - State

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, watermark, focus, shortcuts, permissions

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .watermark: return "textformat"
        case .focus: return "eye.slash"
        case .shortcuts: return "keyboard"
        case .permissions: return "checkmark.shield"
        }
    }
}

/// What the Settings window shows; the island controller keeps it current.
@MainActor
final class SettingsState: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var config = IslandConfig()
    /// The shortcut being recorded, and why the last key press was refused.
    @Published var recording: ShortcutAction?
    @Published var message: String?
    /// Combos another app had registered first.
    @Published var unavailable: Set<KeyCombo> = []
    @Published var loginItem = false
    @Published var islandShown = true
}

// MARK: - Window

/// A regular window (the island is an accessory app, so it activates just for this).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: SettingsWindow
    private weak var island: IslandController?

    init(island: IslandController, store: SessionStore, state: SettingsState) {
        self.island = island
        window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "tabby Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(island: island, store: store, state: state))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TabbySettings")
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { island?.endRecording() }
    func windowDidResignKey(_ notification: Notification) { island?.endRecording() }
}

/// ⌘W closes it (the island has no menu bar to carry the shortcut).
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Root

struct SettingsView: View {
    let island: IslandController
    @ObservedObject var store: SessionStore
    @ObservedObject var state: SettingsState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsTabButton(tab: tab, selected: state.tab == tab) { state.tab = tab }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 6)
            Divider()
            Group {
                switch state.tab {
                case .general: GeneralPane(island: island, store: store, state: state)
                case .watermark: WatermarkPane(island: island, store: store, state: state, permissions: island.permissions)
                case .focus: FocusPane(island: island, store: store, state: state, permissions: island.permissions)
                case .shortcuts: ShortcutsPane(island: island, state: state)
                case .permissions: PermissionsPane(island: island, permissions: island.permissions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 640)
    }
}

struct SettingsTabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(width: 84, height: 50)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.08) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A binding that reads the current setting and hands changes to the island.
private func setting<Value>(_ value: Value, _ set: @escaping (Value) -> Void) -> Binding<Value> {
    Binding(get: { value }, set: { set($0) })
}

// MARK: - General

struct GeneralPane: View {
    let island: IslandController
    @ObservedObject var store: SessionStore
    @ObservedObject var state: SettingsState

    var body: some View {
        let config = state.config
        Form {
            Section("Island") {
                Toggle("Show the island", isOn: setting(state.islandShown) { island.setShown($0) })
                Picker("Detail", selection: setting(config.mode) { island.setMode($0) }) {
                    ForEach(IslandMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Announce when a session is done or needs you", isOn: setting(config.announce) { island.setAnnounce($0) })
                Toggle("Open at login", isOn: setting(state.loginItem) { island.setLoginItem($0) })
            }
            Section {
                Picker("Theme for every tab", selection: setting(config.theme ?? store.snapshot.defaultThemeId ?? "") { island.setThemeAll($0) }) {
                    ForEach(store.snapshot.groups) { group in
                        Section(group.name) {
                            ForEach(store.snapshot.themes.filter { $0.group == group.id }) { theme in
                                Text(theme.name).tag(theme.id)
                            }
                        }
                    }
                }
                Picker("Background tint", selection: setting(config.strength) { island.setStrength($0) }) {
                    Text("Subtle").tag("subtle")
                    Text("Medium").tag("medium")
                    Text("Bold").tag("bold")
                }
                .pickerStyle(.segmented)
                Picker("Color marker in titles", selection: setting(config.marker) { island.setMarker($0) }) {
                    Text("Circle").tag("circle")
                    Text("Square").tag("square")
                    Text("Heart").tag("heart")
                    Text("None").tag("none")
                }
                Picker("Tab names", selection: setting(config.namer) { island.setNamer($0) }) {
                    Text("AI, from your prompts").tag("ai")
                    Text("Local, without AI").tag("heuristic")
                    Text("Off").tag("off")
                }
                Toggle("Animate the spinner and bell in titles", isOn: setting(config.animate) { island.setAnimate($0) })
                Toggle("Terminal.app titles show only the session name", isOn: setting(config.terminalTitles) { island.setTerminalTitles($0) })
            } header: {
                Text("Tabs")
            } footer: {
                Text("Every open tab follows these at once. AI names use Claude Haiku through your own Claude Code login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Watermark

struct WatermarkPane: View {
    let island: IslandController
    @ObservedObject var store: SessionStore
    @ObservedObject var state: SettingsState
    @ObservedObject var permissions: PermissionCenter
    /// The slider's value while it's held (saved on release).
    @State private var draft: Double?

    var body: some View {
        let config = state.config
        var settings = config.watermark
        if let draft { settings.opacity = draft }
        let sample = sampleSession
        let theme = store.theme(sample?.theme ?? store.snapshot.globalThemeId)
        let tint = sample.map { settings.tint(for: $0, themes: store.snapshot.themes, globalTheme: store.snapshot.globalThemeId) }
            ?? NSColor(hexString: settings.color == .session ? "#7fb0ea" : theme?.fg) ?? .white
        return Form {
            Section {
                Toggle(isOn: setting(settings.enabled) { island.setWatermark($0) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show each session's topic behind its Terminal window")
                        Text("Large, faint letters in the session's color. Clicks and typing go straight through.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                WatermarkPreview(title: sample?.title ?? "Stripe Webhook Retries", tint: tint, settings: settings,
                                 background: NSColor(hexString: theme?.bg) ?? NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1),
                                 foreground: NSColor(hexString: theme?.fg) ?? NSColor(white: 0.85, alpha: 1))
                    .frame(height: 196)
                    .opacity(settings.enabled ? 1 : 0.4)
                    .accessibilityLabel("Preview of the watermark")
            }
            Section("Look") {
                LabeledContent("Strength") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { draft ?? config.watermark.opacity },
                                              set: { draft = $0; island.previewWatermarkOpacity($0) }),
                               in: WatermarkSettings.opacityRange, step: 1) { editing in
                            if !editing, let value = draft {
                                island.setWatermarkOpacity(value)
                                draft = nil
                            }
                        }
                        Text("\(Int(settings.opacity.rounded()))%")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .frame(maxWidth: 260)
                }
                Picker("Size", selection: setting(settings.size) { island.setWatermarkSize($0) }) {
                    ForEach(WatermarkSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Color", selection: setting(settings.color) { island.setWatermarkColor($0) }) {
                    ForEach(WatermarkColor.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Position", selection: setting(settings.position) { island.setWatermarkPosition($0) }) {
                    ForEach(WatermarkPosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .disabled(!settings.enabled)
            Section {
                let access = permissions.status(of: .terminal)
                if access == .notAsked || access == .denied {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Tabby Island isn't allowed to control Terminal yet, so it can't tell which window shows which session.")
                        Spacer(minLength: 8)
                        if access == .denied {
                            Button("Ask Again") { permissions.askAgain(.terminal) }
                        } else {
                            Button("Allow") { permissions.requestAutomation(.terminal) }
                        }
                    }
                }
                Text(footnote(config))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    /// The first Terminal session, so the preview shows a real topic in its real colors.
    private var sampleSession: IslandSession? {
        store.listSessions.first { $0.windowId != nil } ?? store.listSessions.first
    }

    private func footnote(_ config: IslandConfig) -> String {
        var text = "Works with Terminal.app. Tabby Island asks Terminal which window shows which session, so macOS asks you once to let it control Terminal."
        if config.hotkeys, let combo = config.shortcuts[.watermark] {
            text += " \(combo.display) turns it on or off from anywhere."
        }
        return text
    }
}

/// A small terminal window with the watermark over it, drawn by the same view the overlays use.
struct WatermarkPreview: NSViewRepresentable {
    var title: String
    var tint: NSColor
    var settings: WatermarkSettings
    var background: NSColor
    var foreground: NSColor

    func makeNSView(context: Context) -> TerminalMockView { TerminalMockView() }

    func updateNSView(_ view: TerminalMockView, context: Context) {
        view.background = background
        view.foreground = foreground
        view.watermark.text = title
        view.watermark.tint = tint
        var shown = settings
        shown.enabled = true
        view.watermark.settings = shown
        view.needsDisplay = true
    }
}

/// A terminal window's silhouette: title bar, a few lines of text, and a watermark on top.
final class TerminalMockView: NSView {
    var background: NSColor = .black
    var foreground: NSColor = .white
    let watermark = WatermarkView()
    private static let titleBar: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        watermark.topInset = Self.titleBar + 6
        addSubview(watermark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        watermark.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        background.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(white: 1, alpha: 0.06).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.titleBar).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(index) * 18, y: 8, width: 11, height: 11)).fill()
        }
        let lines = ["> claude", "", "● I'll retry failed webhooks with exponential backoff.", "  Reading src/webhooks/retry.ts",
                     "  Updated 3 files, 42 tests pass.", "", "> make the max delay configurable"]
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 14, y: Self.titleBar + 12 + CGFloat(index) * 17), withAttributes: [
                .font: font, .foregroundColor: foreground.withAlphaComponent(index == 2 ? 0.95 : 0.72),
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

// MARK: - Focus mode

struct FocusPane: View {
    let island: IslandController
    @ObservedObject var store: SessionStore
    @ObservedObject var state: SettingsState
    @ObservedObject var permissions: PermissionCenter

    var body: some View {
        let on = state.config.focusMode
        return Form {
            Section {
                Toggle(isOn: setting(on) { island.setFocusMode($0) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus mode")
                        Text("While Claude works, Terminal windows you're not in show only their topic and what's running. What Claude writes stays out of sight until it's time to look.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                FocusPreview(content: FocusPane.sample(store))
                    .frame(height: 232)
                    .opacity(on ? 1 : 0.45)
                    .accessibilityLabel("Preview of a covered Terminal window")
            }
            Section("A window opens") {
                FocusReason(symbol: "bell.fill", text: "When Claude needs you: a question or a permission")
                FocusReason(symbol: "checkmark.circle", text: "When it's your turn: Claude is done")
                FocusReason(symbol: "cursorarrow.click", text: "When you click it, or switch to it: the window you type in is never covered")
            }
            .disabled(!on)
            Section {
                let access = permissions.status(of: .terminal)
                if access == .notAsked || access == .denied {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Tabby Island isn't allowed to control Terminal yet, so it can't tell which window shows which session.")
                        Spacer(minLength: 8)
                        if access == .denied {
                            Button("Ask Again") { permissions.askAgain(.terminal) }
                        } else {
                            Button("Allow") { permissions.requestAutomation(.terminal) }
                        }
                    }
                }
                Text("Works with Terminal.app, like the watermark. In Claude: /tab focus-mode on or off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    /// A working session in its own colors (the first Terminal one, else a demo), with agents.
    static func sample(_ store: SessionStore) -> FocusCoverContent {
        let snapshot = store.snapshot
        let now = Date()
        var content: FocusCoverContent
        if let session = store.listSessions.first(where: { $0.windowId != nil }) ?? store.listSessions.first {
            content = FocusCoverContent.make(session, themes: snapshot.themes, globalTheme: snapshot.globalThemeId, now: now)
        } else {
            let theme = snapshot.themes.first { $0.id == snapshot.globalThemeId }
            let fg = NSColor(hexString: theme?.fg) ?? NSColor(white: 0.88, alpha: 1)
            content = FocusCoverContent(sessionId: "sample", title: "Migrate billing to Stripe v3", project: "billing",
                                        background: NSColor(hexString: theme?.bg) ?? NSColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: 1),
                                        foreground: fg, accent: NSColor(hexString: theme?.accents.first?.hex) ?? fg,
                                        mainText: "working", mainDetail: nil, turnStartedAt: nil, agents: [])
        }
        let t = now.timeIntervalSince1970
        content.mainText = "Porting the invoice webhooks to v3"
        content.mainDetail = nil
        content.turnStartedAt = t - 512
        content.agents = [
            FocusAgent(id: "a", label: "Find every Stripe v2 call site", kind: "Explore", tool: "Grep", startedAt: t - 48),
            FocusAgent(id: "b", label: "Write the migration tests", kind: "general-purpose", tool: "Edit", startedAt: t - 131),
        ]
        return content
    }
}

private struct FocusReason: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}

/// A small Terminal window with focus mode's cover over it, drawn by the same view the covers
/// use; its spinners turn while it's on screen.
struct FocusPreview: NSViewRepresentable {
    var content: FocusCoverContent

    func makeNSView(context: Context) -> FocusMockView {
        let view = FocusMockView()
        view.scaledFrom = 760
        return view
    }

    func updateNSView(_ view: FocusMockView, context: Context) {
        view.cover.content = content
        view.needsDisplay = true
    }
}

/// A Terminal window's silhouette: a title bar, and the cover over its content. `scaledFrom`: draw
/// the cover as a window this wide would show it, scaled down (the Settings preview).
final class FocusMockView: NSView {
    let cover = FocusCoverView()
    var animates = true
    var scaledFrom: CGFloat? { didSet { needsLayout = true } }
    private var timer: Timer?
    private static let titleBar: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let frame = NSRect(x: 0, y: Self.titleBar, width: bounds.width, height: max(0, bounds.height - Self.titleBar))
        cover.frame = frame
        let scale = scaledFrom.map { $0 / max(1, frame.width) } ?? 1
        cover.bounds = NSRect(x: 0, y: 0, width: frame.width * scale, height: frame.height * scale)
        cover.cornerRadius = 10 * scale
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil, animates, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cover.advance() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (cover.content?.background ?? .black).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(white: 1, alpha: 0.06).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.titleBar).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(index) * 18, y: 8, width: 11, height: 11)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

// MARK: - Permissions

struct PermissionsPane: View {
    let island: IslandController
    @ObservedObject var permissions: PermissionCenter

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Accessibility",
                              detail: "Tiling splits tabs into their own windows and brings full-screen windows back.",
                              status: permissions.accessibility,
                              allow: { permissions.requestAccessibility() },
                              askAgain: { permissions.requestAccessibility() },
                              openSettings: PermissionCenter.openAccessibilityPane)
                PermissionRow(title: "Control Terminal",
                              detail: "Jump to a session's tab, read tab titles, and find each session's window for the watermark.",
                              status: permissions.status(of: .terminal),
                              allow: { permissions.requestAutomation(.terminal) },
                              askAgain: { permissions.askAgain(.terminal) },
                              openSettings: PermissionCenter.openAutomationPane)
                PermissionRow(title: "Control iTerm2",
                              detail: "Jump to a session's tab in iTerm2 and read its tab titles.",
                              status: permissions.status(of: .iTerm),
                              allow: { permissions.requestAutomation(.iTerm) },
                              askAgain: { permissions.askAgain(.iTerm) },
                              openSettings: PermissionCenter.openAutomationPane)
                PermissionRow(title: "Control System Events",
                              detail: "Tiling clicks Terminal's “Move Tab to New Window” for you.",
                              status: permissions.status(of: .systemEvents),
                              allow: { permissions.requestAutomation(.systemEvents) },
                              askAgain: { permissions.askAgain(.systemEvents) },
                              openSettings: PermissionCenter.openAutomationPane)
            } header: {
                Text("macOS permissions")
            } footer: {
                Text("Checked live. Only the ones for the terminals you use matter (the setup guide asks just for those). tabby uses them only on your Mac: nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Walk through setup again")
                    Spacer()
                    Button("Open Setup Guide") { island.showOnboarding(.welcome, activate: true) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionCenter.Status
    let allow: () -> Void
    let askAgain: () -> Void
    let openSettings: () -> Void

    var body: some View {
        LabeledContent {
            switch status {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .waiting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button("Open System Settings", action: openSettings)
                }
            case .denied:
                HStack(spacing: 8) {
                    Button("Ask Again", action: askAgain)
                    Button("Open System Settings", action: openSettings)
                }
            case .notAsked, .unknown:
                Button("Allow", action: allow)
                    .buttonStyle(.borderedProminent)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    let island: IslandController
    @ObservedObject var state: SettingsState

    private let islandKeys: [(String, String)] = [
        ("↑ ↓", "select a session"), ("↩", "open its tab"), ("1–9", "open session N"),
        ("R", "rename"), ("C", "color"), ("T", "theme"), ("M", "detail level"), ("G", "tile windows"),
        ("W", "watermark"), (",", "settings"), ("esc", "close"),
    ]

    var body: some View {
        let config = state.config
        Form {
            Section {
                Toggle(isOn: setting(config.hotkeys) { island.setHotkeys($0) }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Global shortcuts")
                        Text("They work from any app. Click one to change it, then press the new keys. Delete removes it, Esc cancels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutField(action: action, island: island, state: state)
                    }
                }
                if let message = state.message {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { island.restoreDefaultShortcuts() }
                        .disabled(config.shortcuts == ShortcutAction.defaults)
                }
            }
            .disabled(!config.hotkeys)
            Section("In the island, after \(ShortcutAction.toggle.display(config.shortcuts[.toggle]))") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    ForEach(0..<((islandKeys.count + 1) / 2), id: \.self) { row in
                        GridRow {
                            keyCell(islandKeys[row * 2])
                            if row * 2 + 1 < islandKeys.count { keyCell(islandKeys[row * 2 + 1]) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
    }

    private func keyCell(_ item: (String, String)) -> some View {
        HStack(spacing: 8) {
            Text(item.0)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6)
                .frame(minWidth: 34, minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(item.1)
                .foregroundStyle(.secondary)
        }
        .frame(width: 250, alignment: .leading)
    }
}

/// Click, then press the new keys.
struct ShortcutField: View {
    let action: ShortcutAction
    let island: IslandController
    @ObservedObject var state: SettingsState

    var body: some View {
        let combo = state.config.shortcuts[action]
        let recording = state.recording == action
        HStack(spacing: 6) {
            if let combo, !recording, isTaken(combo) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another app already uses this shortcut, so it doesn't reach tabby. Pick another.")
            }
            Button {
                if recording { island.endRecording() } else { island.beginRecording(action) }
            } label: {
                Text(recording ? "Type shortcut…" : action.display(combo))
                    .font(.system(size: 12, weight: .medium, design: recording || combo == nil ? .default : .rounded))
                    .foregroundStyle(combo == nil && !recording ? Color.secondary : Color.primary)
                    .frame(minWidth: 104)
            }
            .buttonStyle(.bordered)
            .tint(recording ? Color.accentColor : nil)
            .accessibilityLabel("\(action.title): \(recording ? "recording" : action.display(combo))")
            Button {
                if combo == nil { island.setShortcut(action, action.defaultCombo) } else { island.setShortcut(action, nil) }
            } label: {
                Image(systemName: combo == nil ? "arrow.uturn.backward.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .opacity(recording ? 0 : 1)
            .help(combo == nil ? "Use the default, \(action.display(action.defaultCombo))" : "Remove this shortcut")
            .accessibilityLabel(combo == nil ? "Restore the default shortcut" : "Remove this shortcut")
        }
    }

    private func isTaken(_ combo: KeyCombo) -> Bool {
        guard action == .jump else { return state.unavailable.contains(combo) }
        return KeyNames.jumpDigits.contains { state.unavailable.contains(KeyCombo($0, combo.modifiers)) }
    }
}
