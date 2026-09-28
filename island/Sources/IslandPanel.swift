import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Window

/// Borderless, non-activating panel that floats above the menu bar on every Space.
final class IslandPanel: NSPanel {
    /// True only while the island has keyboard focus (⌃⌥Space). Otherwise the panel never
    /// becomes key, so it can't steal typing from the terminal.
    var allowsKey = false

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Clicks work on the first try even though the panel is (almost) never key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Geometry & UI state

struct IslandGeometry: Equatable {
    var hasNotch = false
    var notchWidth: CGFloat = 0
    var barHeight: CGFloat = 32
    var panelSize = CGSize(width: IslandGeometry.panelWidth, height: 680)

    /// Wide enough for an announcement on the right ear; all but the island itself is
    /// transparent and click-through.
    static let panelWidth: CGFloat = 800

    /// Island geometry plus the panel frame (screen coordinates) for the preferred screen.
    @MainActor
    static func current() -> (IslandGeometry, NSRect) {
        var geometry = IslandGeometry()
        guard let screen = preferredScreen() else {
            return (geometry, NSRect(origin: .zero, size: geometry.panelSize))
        }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            geometry.hasNotch = true
            geometry.notchWidth = max(0, frame.width - left.width - right.width)
            geometry.barHeight = screen.safeAreaInsets.top
        } else {
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            geometry.barHeight = menuBar > 0 ? menuBar : NSStatusBar.system.thickness
        }
        geometry.barHeight = min(max(geometry.barHeight, 22), 44)
        let width = min(panelWidth, frame.width)
        let height = min(680, (frame.height * 0.8).rounded())
        geometry.panelSize = CGSize(width: width, height: height)
        let rect = NSRect(x: (frame.midX - width / 2).rounded(), y: frame.maxY - height, width: width, height: height)
        return (geometry, rect)
    }

    /// The built-in notched display if there is one, else the main screen.
    @MainActor
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

@MainActor
final class IslandUIState: ObservableObject {
    @Published var expanded = false
    /// The row under the mouse, or the one selected with the arrow keys.
    @Published var hoveredRow: String?
    @Published var geometry = IslandGeometry()
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var mode: IslandMode = .standard
    /// The island has keyboard focus (opened with ⌃⌥Space).
    @Published var keyboard = false
    /// The live activity in the collapsed pill.
    @Published var announcement: Announcement?
    /// A newer tabby is out, or one is being installed (the header's Update pill).
    @Published var update: UpdateBadge?
    /// The session whose title is being edited in place, and the text so far.
    @Published var renaming: String?
    @Published var renameText = ""
    /// Snapshot renders: no entrance animations, no blinking.
    var staticRender = false
    var menuOpen = false

    /// Something needs the expanded island to stay open even without the mouse.
    var holdsOpen: Bool { keyboard || renaming != nil || menuOpen }
}

/// Callbacks from the SwiftUI tree back into the controller.
struct IslandActions {
    var islandFrame: @MainActor (CGRect) -> Void
    var rowFrames: @MainActor ([String: CGRect]) -> Void
    var viewport: @MainActor (CGRect) -> Void
    /// Expands the island, or acts on the announcement it shows.
    var tapHeader: @MainActor () -> Void
    var tapRow: @MainActor (IslandSession) -> Void
    var sessionMenu: @MainActor (IslandSession) -> Void
    var themeAllMenu: @MainActor () -> Void
    var setMode: @MainActor (IslandMode) -> Void
    var tileMenu: @MainActor () -> Void
    var openSettings: @MainActor () -> Void
    /// Installs the newer tabby (the Update pill).
    var update: @MainActor () -> Void
    /// Inline rename: Return commits (empty lets AI name it), Esc cancels.
    var commitRename: @MainActor () -> Void
    var cancelRename: @MainActor () -> Void

    static let inert = IslandActions(islandFrame: { _ in }, rowFrames: { _ in }, viewport: { _ in }, tapHeader: {},
                                     tapRow: { _ in }, sessionMenu: { _ in }, themeAllMenu: {}, setMode: { _ in },
                                     tileMenu: {}, openSettings: {}, update: {}, commitRename: {}, cancelRename: {})
}

/// Settings the user just changed, by config key: applied at once, and kept until config.json
/// (written by the CLI in the background) agrees, or changes to something else, which then wins.
private struct PendingConfig {
    private var entries: [String: (value: ConfigValue, baseline: ConfigValue?)] = [:]

    mutating func set(_ key: String, _ value: ConfigValue, file: ConfigValue?) {
        entries[key] = (value, file)
    }

    func value(_ key: String) -> ConfigValue? { entries[key]?.value }

    /// The file's values with the pending ones on top; forgets those the file has caught up with.
    mutating func resolve(_ file: [String: ConfigValue]) -> [String: ConfigValue] {
        var out = file
        for (key, entry) in entries {
            let current = file[key]
            if current == entry.value || current != entry.baseline {
                entries[key] = nil
            } else {
                out[key] = entry.value
            }
        }
        return out
    }
}

// MARK: - Controller

/// Owns the panel and does hover tracking in AppKit: the panel ignores mouse events
/// everywhere except over the island shape, so the transparent rest of the panel (and
/// the menu bar under it) stays fully clickable.
@MainActor
final class IslandController {
    let store: SessionStore
    let ui = IslandUIState()

    private var panel: IslandPanel?
    private var host: NSView?
    private var islandFrame: CGRect = .zero
    private var rowFrames: [String: CGRect] = [:]
    private var viewport: CGRect = .zero
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var pollTimer: Timer?
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var lastMouse = CGPoint(x: -1, y: -1)
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private(set) var isShown = false

    // Settings: config.json overlaid with changes the CLI is still writing.
    private(set) var config = IslandConfig()
    private var pending = PendingConfig()
    private var configLoaded = false
    /// What the Settings window shows.
    let settingsState = SettingsState()
    private var settingsWindow: SettingsWindowController?
    /// Records the next key press as a shortcut (Settings › Shortcuts).
    private var recordMonitor: Any?

    /// Each Terminal session's topic, large and faint, over its window.
    let watermark = WatermarkController()
    /// The strength shown while Settings' slider moves (saved when it's let go).
    private var watermarkPreview: Double?

    // Keyboard focus (⌃⌥Space).
    private var previousApp: NSRunningApplication?
    private var shownForKeyboard = false
    /// The panel became key only for an inline rename started with the mouse.
    private var renameTookFocus = false
    private var lastJump: (id: String, at: Date)?

    // Live activities.
    private var announcements: [Announcement] = []
    private var announcementWork: DispatchWorkItem?
    private var announcementHeld = false
    private var lastStatuses: [String: SessionStatus]?
    private var suppressExpandUntil = Date.distantPast

    private let expandDelay = 0.12
    private let collapseDelay = 0.35

    /// Snapshot renders: no global shortcuts, no watermark windows.
    private let inert: Bool
    /// What macOS allows the island (Accessibility, Automation), for the onboarding and Settings.
    let permissions: PermissionCenter
    /// Newer versions of tabby: checking, and installing one.
    let updates: UpdateCenter
    private var onboarding: OnboardingWindowController?

    init(store: SessionStore, inert: Bool = false) {
        self.store = store
        self.inert = inert
        permissions = inert
            ? PermissionCenter(accessibility: .allowed, automation: [.terminal: .waiting, .systemEvents: .notAsked])
            : PermissionCenter()
        updates = inert
            ? UpdateCenter(info: .init(current: "0.3.0", latest: "0.3.1", available: true, checkedAt: Date().addingTimeInterval(-7200)))
            : UpdateCenter()
        buildPanel()
        if !inert { Self.current = self }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ui.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelResignedKey() }
        })
        store.$snapshot
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated { self?.storeChanged(snapshot) }
            }
            .store(in: &cancellables)
        watermark.onUnknownWindow = { [weak store] in store?.requestTerminalWindows() }
        watermark.onCoverClick = { [weak store] id in
            if let session = store?.session(id: id) { Actions.focus(session) }
        }
        permissions.onTerminalAllowed = { [weak store] in store?.requestTerminalWindows() }
        permissions.sessionTerms = { [weak store] in Set(store?.snapshot.sessions.compactMap(\.term) ?? []) }
        if !inert { permissions.startBackgroundChecks() }
        if !inert {
            SessionDetailModel.shared.announceFailure = { [weak self] text in
                self?.enqueue(Announcement(kind: .info, title: text, symbol: "exclamationmark.triangle.fill", topic: "end-session",
                                           detail: text), force: true)
            }
        }
        updates.announce = { [weak self] text, symbol in
            self?.enqueue(Announcement(kind: .info, title: text, symbol: symbol, topic: "update"), force: true)
        }
        Publishers.CombineLatest(updates.$info, updates.$phase)
            .sink { [weak self] info, phase in
                MainActor.assumeIsolated {
                    guard let self, !self.inert else { return }
                    let badge: UpdateBadge?
                    if case .updating = phase { badge = .updating }
                    else if info.available, let latest = info.latest { badge = .available(latest) }
                    else { badge = nil }
                    if self.ui.update != badge { self.ui.update = badge }
                }
            }
            .store(in: &cancellables)
        if !inert { updates.start(automatic: false) }
        settingsState.loginItem = Self.loginItemInstalled
        installDebugChannel()
    }

    /// Shows or hides the island and remembers it (status menu, Settings).
    func setShown(_ on: Bool) {
        if on { show() } else { hide() }
        UserDefaults.standard.set(isShown, forKey: "showIsland")
        settingsState.islandShown = isShown
    }

    func show() {
        guard let panel, !isShown else { return }
        isShown = true
        reposition()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        installMonitors()
    }

    func hide() {
        guard isShown else { return }
        shownForKeyboard = false
        endKeyboard(restoreFocus: true)
        announcements.removeAll()
        endAnnouncement(animated: false)
        isShown = false
        setExpanded(false)
        panel?.orderOut(nil)
        removeMonitors()
        setPolling(false)
    }

    func reposition() {
        let (geometry, rect) = IslandGeometry.current()
        if ui.geometry != geometry { ui.geometry = geometry }
        panel?.setFrame(rect, display: true)
    }

    // MARK: Setup

    private func buildPanel() {
        let (geometry, rect) = IslandGeometry.current()
        ui.geometry = geometry
        let actions = IslandActions(
            islandFrame: { [weak self] frame in self?.islandFrame = frame },
            rowFrames: { [weak self] frames in self?.rowFrames = frames },
            viewport: { [weak self] frame in self?.viewport = frame },
            tapHeader: { [weak self] in self?.tapHeader() },
            tapRow: { [weak self] session in self?.focus(session) },
            sessionMenu: { [weak self] session in self?.showSessionMenu(session) },
            themeAllMenu: { [weak self] in self?.showThemeAllMenu() },
            setMode: { [weak self] mode in self?.setMode(mode) },
            tileMenu: { [weak self] in self?.showTileMenu() },
            openSettings: { [weak self] in self?.openSettings() },
            update: { [weak self] in self?.updates.update() },
            commitRename: { [weak self] in self?.commitRename() },
            cancelRename: { [weak self] in self?.cancelRename() }
        )
        let host = IslandHostingView(rootView: IslandRootView(store: store, ui: ui, actions: actions))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: rect.size)
        host.autoresizingMask = [.width, .height]
        let panel = IslandPanel(contentRect: rect)
        panel.contentView = host
        self.panel = panel
        self.host = host
    }

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse() }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    // MARK: Store & settings

    private func storeChanged(_ snapshot: StoreSnapshot) {
        guard snapshot.loaded else { return }
        resolveConfig(snapshot)
        updateWatermark(snapshot)
        detectTransitions(snapshot)
        if let id = ui.renaming, !snapshot.sessions.contains(where: { $0.id == id }) {
            finishRename(commit: false)   // the session ended under the field
        }
        if ui.keyboard, let row = ui.hoveredRow, !snapshot.sessions.contains(where: { $0.id == row }) {
            ui.hoveredRow = SessionStore.listOrder(snapshot.sessions).first?.id
        }
    }

    private func resolveConfig(_ snapshot: StoreSnapshot) {
        let next = IslandConfig(raw: pending.resolve(snapshot.configRaw))
        let first = !configLoaded
        configLoaded = true
        guard first || next != config else { return }
        let old = config
        config = next
        settingsState.config = next
        if ui.mode != next.mode {
            if first {
                ui.mode = next.mode
            } else {
                withAnimation(ui.reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.4, dampingFraction: 0.86)) {
                    ui.mode = next.mode
                }
            }
        }
        if first || next.hotkeys != old.hotkeys || next.shortcuts != old.shortcuts { updateHotkeys() }
        if old.announce, !next.announce {
            announcements.removeAll { $0.kind != .info }
            if ui.announcement?.kind != .info { endAnnouncement() }
        }
        if first || next.watermark != old.watermark || next.focusMode != old.focusMode { updateWatermark(snapshot) }
        if first || next.updateCheck != old.updateCheck { updates.setAutomatic(next.updateCheck) }
    }

    /// Applies a setting at once and has the CLI write it: `tabby config <key> <json>`, or
    /// `command` when the setting needs more than a write (repainting every tab, say).
    func setSetting(_ key: String, _ value: ConfigValue, command: [String]? = nil) {
        guard (pending.value(key) ?? store.snapshot.configRaw[key]) != value else { return }
        pending.set(key, value, file: store.snapshot.configRaw[key])
        if let command { Actions.runCLI(command) } else { Actions.setConfig(key, json: value.json) }
        resolveConfig(store.snapshot)
    }

    func setMode(_ mode: IslandMode) {
        guard mode != config.mode else { return }
        setSetting("islandMode", .string(mode.rawValue))
    }

    func setAnnounce(_ on: Bool) { setSetting("islandAnnounce", .bool(on)) }
    func setHotkeys(_ on: Bool) { setSetting("islandHotkeys", .bool(on)) }

    // Tabby's own settings, as the CLI changes them (every open tab follows at once).
    func setThemeAll(_ id: String) { setSetting("theme", .string(id), command: ["theme", id, "--all"]) }
    func setNamer(_ value: String) { setSetting("namer", .string(value), command: ["namer", value]) }
    func setStrength(_ value: String) { setSetting("strength", .string(value), command: ["strength", value]) }
    func setMarker(_ value: String) { setSetting("marker", .string(value), command: ["marker", value]) }
    func setAnimate(_ on: Bool) { setSetting("animate", .bool(on)) }
    func setTerminalTitles(_ on: Bool) {
        setSetting("terminalTabTitles", .bool(on), command: ["terminal-titles", on ? "on" : "off"])
    }

    // MARK: Watermark

    func setWatermark(_ on: Bool) { setSetting("watermark", .bool(on)) }
    func setWatermarkOpacity(_ percent: Double) {
        watermarkPreview = nil
        setSetting("watermarkOpacity", .number(percent.rounded()))
        updateWatermark(store.snapshot)
    }
    func setWatermarkSize(_ size: WatermarkSize) { setSetting("watermarkSize", .string(size.rawValue)) }
    func setWatermarkColor(_ color: WatermarkColor) { setSetting("watermarkColor", .string(color.rawValue)) }
    func setWatermarkPosition(_ position: WatermarkPosition) { setSetting("watermarkPosition", .string(position.rawValue)) }

    /// Shows a strength on every watermark while the slider moves, without saving it yet.
    func previewWatermarkOpacity(_ percent: Double?) {
        watermarkPreview = percent
        updateWatermark(store.snapshot)
    }

    /// ⌃⌥W: on or off; while collapsed the pill says which.
    func toggleWatermark() {
        let on = !config.watermark.enabled
        setWatermark(on)
        if !ui.expanded {
            enqueue(.info(on ? "Watermark on" : "Watermark off", symbol: "textformat", topic: "watermark"),
                    force: true)
        }
    }

    // MARK: Focus mode

    func setFocusMode(_ on: Bool) { setSetting("focusMode", .bool(on)) }
    func setUpdateCheck(_ on: Bool) { setSetting("updateCheck", .bool(on)) }

    private func updateWatermark(_ snapshot: StoreSnapshot) {
        guard !inert else { return }
        var settings = config.watermark
        if let watermarkPreview { settings.opacity = watermarkPreview }
        watermark.apply(settings, focusMode: config.focusMode)
        watermark.update(snapshot) { session in
            settings.tint(for: session, themes: snapshot.themes, globalTheme: snapshot.globalThemeId)
        }
    }

    // MARK: Shortcuts

    func setShortcut(_ action: ShortcutAction, _ combo: KeyCombo?) {
        var shortcuts = config.shortcuts
        shortcuts[action] = combo
        setSetting("islandShortcuts", .object(shortcuts.overrides))
    }

    func restoreDefaultShortcuts() {
        settingsState.message = nil
        setSetting("islandShortcuts", .object([:]))
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .toggle: toggleKeyboard()
        case .next: jumpToNextNeedingYou()
        case .jump: focusSession(at: 0)
        case .tile: tile(nil)
        case .launch: showQuickLaunch()
        case .mode: cycleMode()
        case .watermark: toggleWatermark()
        case .settings: openSettings()
        }
    }

    /// Settings › Shortcuts: the next key press becomes `action`'s shortcut. Global shortcuts
    /// are off meanwhile, so pressing a current one records it instead of running it.
    func beginRecording(_ action: ShortcutAction) {
        endRecording()
        settingsState.message = nil
        settingsState.recording = action
        HotkeyCenter.shared.disable()
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.record(event) ?? false }
            return consumed ? nil : event
        }
    }

    func endRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        guard settingsState.recording != nil else { return }
        settingsState.recording = nil
        updateHotkeys()
    }

    private func record(_ event: NSEvent) -> Bool {
        guard let action = settingsState.recording else { return false }
        let code = Int(event.keyCode)
        let modifiers = KeyModifiers(event.modifierFlags)
        if code == kVK_Escape, modifiers.isEmpty {
            endRecording()
            return true
        }
        if code == kVK_Delete || code == kVK_ForwardDelete, modifiers.isEmpty {
            setShortcut(action, nil)
            endRecording()
            return true
        }
        func refuse(_ message: String) -> Bool {
            settingsState.message = message
            NSSound.beep()
            return true
        }
        guard KeyNames.label(for: code) != nil else { return refuse("That key can't be part of a shortcut.") }
        let combo = KeyCombo(code, modifiers)
        if action == .jump, !combo.isDigit { return refuse("Press the modifiers with a digit, like ⌃⌥1.") }
        if modifiers.intersection([.control, .option, .command]).isEmpty, !combo.isFunctionKey {
            return refuse("Add ⌃, ⌥ or ⌘, so the shortcut doesn't get in the way of typing.")
        }
        for other in ShortcutAction.allCases where other != action {
            if let existing = config.shortcuts[other], action.collides(combo, with: existing, of: other) {
                return refuse("\(action.display(combo)) is already “\(other.title)”.")
            }
        }
        setShortcut(action, combo)
        endRecording()
        return true
    }

    // MARK: Onboarding

    /// The first-run window: welcome, permissions, shortcuts. `activate`: take keyboard focus
    /// (asked for by the user); otherwise it just appears in front.
    func showOnboarding(_ page: OnboardingPage = .welcome, activate: Bool) {
        if ui.keyboard { endKeyboard(restoreFocus: false) } else { setExpanded(false) }
        settingsState.loginItem = Self.loginItemInstalled
        let window = onboarding ?? OnboardingWindowController(island: self, permissions: permissions, state: settingsState)
        window.onClose = { [weak self] in self?.onboardingClosed() }
        onboarding = window
        window.show(page: page, activate: activate)
    }

    private func onboardingClosed() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        // Show where the island lives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isShown, !self.ui.expanded else { return }
                self.enqueue(.info("tabby lives here: hover to see every session", symbol: "arrow.up.circle.fill",
                                   topic: "welcome"), force: true)
            }
        }
    }

    // MARK: Settings window

    func openSettings(_ tab: SettingsTab? = nil) {
        if ui.keyboard { endKeyboard(restoreFocus: false) } else { setExpanded(false) }
        if let tab { settingsState.tab = tab }
        settingsState.islandShown = isShown
        settingsState.loginItem = Self.loginItemInstalled
        let window = settingsWindow ?? SettingsWindowController(island: self, store: store, state: settingsState)
        settingsWindow = window
        window.show()
    }

    private static var loginAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/dev.tabby.island.plist")
    }

    static var loginItemInstalled: Bool { FileManager.default.fileExists(atPath: loginAgent.path) }

    func setLoginItem(_ on: Bool) {
        settingsState.loginItem = on
        Actions.runCLI(on ? ["island", "login"] : ["island", "login", "--off"]) { [weak self] _, _ in
            self?.settingsState.loginItem = Self.loginItemInstalled
        }
    }

    /// ⌃⌥M: the next density; while collapsed the pill says which one.
    func cycleMode() {
        let next = config.mode.next
        setMode(next)
        if !ui.expanded { enqueue(.info("\(next.title) mode", symbol: next.symbol, topic: "mode"), force: true) }
    }

    private func updateHotkeys() {
        guard !inert else { return }
        let center = HotkeyCenter.shared
        guard config.hotkeys, settingsState.recording == nil else {
            center.disable()
            if settingsState.recording == nil { settingsState.unavailable = [] }
            return
        }
        var bindings: [HotkeyCenter.Binding] = []
        for action in ShortcutAction.allCases {
            guard let combo = config.shortcuts[action] else { continue }
            if action == .jump {
                for (index, code) in KeyNames.jumpDigits.enumerated() {
                    bindings.append(.init(combo: KeyCombo(code, combo.modifiers)) { [weak self] in self?.focusSession(at: index) })
                }
            } else {
                bindings.append(.init(combo: combo) { [weak self] in self?.perform(action) })
            }
        }
        center.enable(bindings)
        settingsState.unavailable = center.unavailable
    }

    // MARK: Hover tracking

    private func mouseInPanel() -> CGPoint? {
        guard let panel else { return nil }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)   // top-left origin, like SwiftUI
    }

    private func isInsideIsland(_ point: CGPoint) -> Bool {
        !islandFrame.isEmpty && islandFrame.insetBy(dx: -2, dy: -2).contains(point)
    }

    private func handleMouse() {
        guard isShown, let panel, let point = mouseInPanel() else { return }
        let moved = abs(point.x - lastMouse.x) > 0.5 || abs(point.y - lastMouse.y) > 0.5
        lastMouse = point
        let inside = isInsideIsland(point)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            setPolling(true)
            if !ui.expanded {
                if ui.announcement != nil {
                    holdAnnouncement()
                } else if expandWork == nil, Date() >= suppressExpandUntil {
                    scheduleExpand()
                }
            } else if moved {
                updateRowHover(point)
            }
        } else {
            expandWork?.cancel()
            expandWork = nil
            releaseAnnouncement()
            if ui.expanded {
                if !ui.holdsOpen, collapseWork == nil { scheduleCollapse() }
            } else {
                setPolling(false)
            }
            if !ui.holdsOpen, ui.hoveredRow != nil { setHoveredRow(nil) }
        }
    }

    private func updateRowHover(_ point: CGPoint) {
        guard !ui.menuOpen, ui.renaming == nil else { return }
        var hit: String?
        if viewport.isEmpty || viewport.contains(point) {
            hit = rowFrames.first { $0.value.contains(point) }?.key
        }
        // With the keyboard, the selection stays put when the mouse slips between rows.
        if ui.keyboard && hit == nil { return }
        if hit != ui.hoveredRow { setHoveredRow(hit) }
    }

    private func setHoveredRow(_ id: String?) {
        withAnimation(ui.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
            ui.hoveredRow = id
        }
    }

    private func scheduleExpand() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expandWork = nil
                guard self.ui.announcement == nil else { return }
                if let point = self.mouseInPanel(), self.isInsideIsland(point) { self.setExpanded(true) }
            }
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay, execute: work)
    }

    private func scheduleCollapse() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.collapseWork = nil
                guard !self.ui.holdsOpen else { return }
                if let point = self.mouseInPanel(), self.isInsideIsland(point) { return }
                self.setExpanded(false)
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
    }

    func setExpanded(_ value: Bool) {
        expandWork?.cancel()
        expandWork = nil
        collapseWork?.cancel()
        collapseWork = nil
        guard ui.expanded != value else { return }
        if !value, ui.renaming != nil { finishRename(commit: false) }
        if value {
            // The list says it all; drop session news, keep notices (tiling, Accessibility).
            announcements.removeAll { $0.kind != .info }
            endAnnouncement(animated: false)
        }
        let animation: Animation = ui.reduceMotion
            ? .easeInOut(duration: 0.14)
            : (value ? .spring(response: 0.42, dampingFraction: 0.8) : .spring(response: 0.34, dampingFraction: 0.92))
        withAnimation(animation) {
            ui.expanded = value
            if !value && !ui.keyboard { ui.hoveredRow = nil }
        }
        if !value {
            rowFrames = [:]
            if !announcements.isEmpty { showNextAnnouncement(after: 0.45) }
        }
        setPolling(value)
    }

    /// A light 10 Hz poll while hovered/expanded catches exits the event monitors miss.
    private func setPolling(_ on: Bool) {
        if on {
            guard pollTimer == nil else { return }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMouse() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: Live activities

    /// Sessions that finish a turn or start waiting, compared with the previous load. Never
    /// on the first load, never for sessions that just appeared.
    private func detectTransitions(_ snapshot: StoreSnapshot) {
        var statuses: [String: SessionStatus] = [:]
        for session in snapshot.sessions { statuses[session.id] = session.status }
        defer { lastStatuses = statuses }
        guard let previous = lastStatuses, config.announce, isShown else { return }
        for session in SessionStore.listOrder(snapshot.sessions) {
            guard let before = previous[session.id], before != session.status else { continue }
            if session.status == .waiting {
                enqueue(.waiting(session))
            } else if before == .busy, session.status.isYourTurn {
                enqueue(.done(session))
            }
        }
    }

    /// Queues an announcement. `force` shows notices even with announcements turned off.
    func enqueue(_ announcement: Announcement, force: Bool = false) {
        guard isShown, force || config.announce else { return }
        if ui.expanded && announcement.kind != .info { return }
        if let topic = announcement.topic, let current = ui.announcement, current.topic == topic {
            withAnimation(announceAnimation) { ui.announcement = announcement }
            if !announcementHeld { scheduleAnnouncementEnd(after: announcement.duration) }
            return
        }
        announcements.removeAll { $0.topic != nil && $0.topic == announcement.topic }
        announcements.append(announcement)
        if announcements.count > 5 { announcements.removeFirst(announcements.count - 5) }
        if ui.announcement == nil { showNextAnnouncement() }
    }

    private var announceAnimation: Animation {
        ui.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.44, dampingFraction: 0.7)
    }

    private func showNextAnnouncement(after delay: Double = 0) {
        guard delay <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.showNextAnnouncement() }
            }
            return
        }
        guard ui.announcement == nil, !ui.expanded, isShown, !announcements.isEmpty else { return }
        let next = announcements.removeFirst()
        Debug.log("announce \(next.title) \(next.suffix ?? "")")
        withAnimation(announceAnimation) { ui.announcement = next }
        scheduleAnnouncementEnd(after: next.duration)
        // Already under the mouse: hold it right away.
        if let point = mouseInPanel(), isInsideIsland(point) { holdAnnouncement() }
    }

    private func scheduleAnnouncementEnd(after seconds: Double) {
        announcementWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endAnnouncement() }
        }
        announcementWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func endAnnouncement(animated: Bool = true) {
        announcementWork?.cancel()
        announcementWork = nil
        announcementHeld = false
        guard ui.announcement != nil else { return }
        if animated {
            withAnimation(ui.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.9)) {
                ui.announcement = nil
            }
        } else {
            ui.announcement = nil
        }
        if !announcements.isEmpty { showNextAnnouncement(after: 0.45) }
    }

    /// The pointer is on the pill: keep the announcement up (and don't expand under it).
    private func holdAnnouncement() {
        guard ui.announcement != nil, !announcementHeld else { return }
        announcementHeld = true
        announcementWork?.cancel()
        announcementWork = nil
    }

    private func releaseAnnouncement() {
        guard announcementHeld else { return }
        announcementHeld = false
        scheduleAnnouncementEnd(after: 1.5)
    }

    private func tapHeader() {
        guard let announcement = ui.announcement else {
            setExpanded(true)
            return
        }
        if announcement.opensAccessibility {
            showOnboarding(.permissions, activate: true)
        } else if let session = store.session(id: announcement.sessionId) {
            Actions.focus(session)
        }
        suppressExpandUntil = Date().addingTimeInterval(1.2)
        endAnnouncement()
    }

    // MARK: Keyboard focus (⌃⌥Space)

    func toggleKeyboard() {
        if ui.keyboard { endKeyboard(restoreFocus: true) } else { beginKeyboard() }
    }

    private func beginKeyboard() {
        guard let panel else { return }
        Debug.log("keyboard begins; front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        if !isShown {
            show()
            shownForKeyboard = true
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        announcements.removeAll { $0.kind != .info }
        endAnnouncement(animated: false)
        panel.allowsKey = true
        withAnimation(ui.reduceMotion ? nil : .easeOut(duration: 0.18)) { ui.keyboard = true }
        setExpanded(true)
        let ids = store.listSessions.map(\.id)
        if ui.hoveredRow.map({ !ids.contains($0) }) ?? true { ui.hoveredRow = ids.first }
        // A non-activating panel takes key focus without activating the island: the
        // terminal keeps its menu bar, and Esc hands focus straight back.
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private func endKeyboard(restoreFocus: Bool) {
        guard ui.keyboard else { return }
        Debug.log("keyboard ends; restore=\(restoreFocus) previous=\(previousApp?.localizedName ?? "-")")
        removeKeyMonitor()
        withAnimation(ui.reduceMotion ? nil : .easeOut(duration: 0.15)) { ui.keyboard = false }
        panel?.allowsKey = false
        setExpanded(false)
        let app = previousApp
        previousApp = nil
        relinquishKeyFocus(reactivating: restoreFocus ? app : nil)
        if shownForKeyboard {
            shownForKeyboard = false
            hide()
        }
    }

    /// Hands key focus back. The key panel made the island "active" without taking the
    /// menu bar; deactivating returns key focus to the frontmost app's window. `app` is
    /// re-activated only if something else came to the front meanwhile.
    private func relinquishKeyFocus(reactivating app: NSRunningApplication?) {
        NSApp.deactivate()
        if let app, !app.isTerminated, NSWorkspace.shared.frontmostApplication != app { app.activate(options: []) }
        // Belt and braces: if the panel is somehow still key, order it out and back in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isKeyWindow, !self.ui.keyboard else { return }
                Debug.log("panel still key after activating the previous app; reordering")
                panel.orderOut(nil)
                if self.isShown { panel.orderFrontRegardless() }
            }
        }
    }

    private func panelResignedKey() {
        // Clicked elsewhere: keep a rename that was typed (like Finder), drop keyboard mode.
        guard !ui.menuOpen else { return }
        if ui.renaming != nil { finishRename(commit: true, restoreFocus: false) }
        if ui.keyboard { endKeyboard(restoreFocus: false) }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // While renaming, every key belongs to the text field (Return and Esc included).
        guard ui.keyboard, ui.renaming == nil, let panel, event.window === panel else { return false }
        Debug.log("key \(event.keyCode) \(event.charactersIgnoringModifiers ?? "")")
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        switch Int(event.keyCode) {
        case kVK_UpArrow: moveSelection(by: -1)
        case kVK_DownArrow: moveSelection(by: 1)
        case kVK_Tab: moveSelection(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        case kVK_Return, kVK_ANSI_KeypadEnter: if let session = selectedSession() { focus(session) }
        case kVK_Escape: endKeyboard(restoreFocus: true)
        default:
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if let digit = Int(key), (1...9).contains(digit) {
                focusSession(at: digit - 1)
            } else {
                switch key {
                case "r": if let session = selectedSession() { startRename(session) }
                case "c": showSelectionMenu(color: true)
                case "t": showSelectionMenu(color: false)
                case "m": setMode(config.mode.next)
                case "g": tile(nil)
                case "w": toggleWatermark()
                case ",": openSettings()
                default: break   // swallowed: nothing leaks to the terminal or beeps
                }
            }
        }
        return true
    }

    private func selectedSession() -> IslandSession? {
        store.session(id: ui.hoveredRow)
    }

    private func moveSelection(by delta: Int) {
        let ids = store.listSessions.map(\.id)
        guard !ids.isEmpty else { return }
        let index = ui.hoveredRow.flatMap { ids.firstIndex(of: $0) }
        let next = index.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
        setHoveredRow(ids[next])
    }

    private func showSelectionMenu(color: Bool) {
        guard let session = selectedSession() else { return }
        let factory = MenuFactory.shared
        let menu = color
            ? factory.colorMenu(for: session, store: store)
            : factory.themeMenu(store: store, current: session.theme ?? store.snapshot.globalThemeId) { id in
                Actions.setTheme(session, id: id)
            }
        let frame = rowFrames[session.id] ?? islandFrame
        popUp(menu, at: CGPoint(x: frame.minX + 38, y: frame.maxY - 4))
    }

    // MARK: Jumping & tiling

    /// ⌃⌥1…9 and 1…9 with keyboard focus: the Nth session in list order.
    func focusSession(at index: Int) {
        let list = store.listSessions
        guard list.indices.contains(index) else {
            if !ui.expanded {
                enqueue(.info(list.isEmpty ? "No Claude sessions" : "No session \(index + 1)",
                              symbol: "number.circle.fill", topic: "jump"), force: true)
            }
            return
        }
        focus(list[index])
    }

    /// ⌃⌥N: waiting sessions (oldest first), then "your turn" and errors (most recent
    /// first), cycling on each press — the same order as `tabby next`.
    func jumpToNextNeedingYou() {
        let sessions = store.snapshot.sessions
        let waiting = sessions.filter { $0.status == .waiting }
            .sorted { ($0.activityAt ?? 0) < ($1.activityAt ?? 0) }
        let turn = sessions.filter { $0.status.isYourTurn || $0.status == .error }
            .sorted { ($0.activityAt ?? 0) > ($1.activityAt ?? 0) }
        let candidates = waiting + turn
        guard !candidates.isEmpty else {
            enqueue(.info(sessions.isEmpty ? "No Claude sessions" : "Nothing needs you right now",
                          symbol: "checkmark.circle.fill", topic: "jump"), force: true)
            return
        }
        var index = 0
        if let last = lastJump, Date().timeIntervalSince(last.at) < 90,
           let i = candidates.firstIndex(where: { $0.id == last.id }) {
            index = (i + 1) % candidates.count
        }
        lastJump = (candidates[index].id, Date())
        focus(candidates[index])
    }

    /// `tabby tile [n] [--active | --only …]`; the CLI's notices (Accessibility above all) show in the pill.
    func tile(_ count: Int?, extra: [String] = []) {
        if ui.keyboard { endKeyboard(restoreFocus: true) } else { setExpanded(false) }
        Actions.tile(count, extra: extra) { [weak self] output in
            Debug.log("tile output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            guard let self, let notice = Actions.notice(fromTileOutput: output) else { return }
            if notice.accessibility {
                self.enqueue(.info("Allow Accessibility to split tabs", symbol: "hand.raised.fill", topic: "tile",
                                   detail: notice.text + "\nClick to open System Settings.",
                                   opensAccessibility: true), force: true)
            } else {
                self.enqueue(.info(notice.text, symbol: "square.grid.2x2", topic: "tile", detail: notice.text),
                             force: true)
            }
        }
    }

    // MARK: Row actions

    private func focus(_ session: IslandSession) {
        if ui.keyboard { endKeyboard(restoreFocus: false) } else { setExpanded(false) }
        Actions.focus(session)
    }

    private func showSessionMenu(_ session: IslandSession) {
        let menu = MenuFactory.shared.sessionMenu(for: session, store: store) { [weak self] in
            // After the menu has closed, so the field can take focus.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.startRename(session) } }
        }
        popUp(menu)
    }

    private func showThemeAllMenu() {
        let menu = MenuFactory.shared.themeMenu(store: store, current: store.snapshot.globalThemeId) { id in
            Actions.setThemeAll(id)
        }
        popUp(menu)
    }

    private func showTileMenu() {
        let menu = MenuFactory.shared.tileMenu(sessionCount: store.snapshot.sessions.count) { [weak self] count in
            self?.tile(count)
        }
        popUp(menu)
    }

    /// Pops a menu at the mouse, or at a point in the island's (top-left origin) coordinates.
    private func popUp(_ menu: NSMenu, at point: CGPoint? = nil) {
        ui.menuOpen = true
        collapseWork?.cancel()
        collapseWork = nil
        if let point, let host {
            let location = host.isFlipped ? point : CGPoint(x: point.x, y: host.bounds.height - point.y)
            _ = menu.popUp(positioning: nil, at: location, in: host)
        } else {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        ui.menuOpen = false
        handleMouse()
    }

    // MARK: Inline rename

    /// Turns the row's title into a text field. With the mouse, the panel takes key focus
    /// just for the field (without activating the island) and hands it back afterwards.
    func startRename(_ session: IslandSession) {
        guard let panel, ui.renaming == nil else { return }
        if !ui.keyboard {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            renameTookFocus = true
        }
        setExpanded(true)
        panel.allowsKey = true
        ui.renameText = session.title
        withAnimation(ui.reduceMotion ? nil : .easeOut(duration: 0.15)) {
            ui.hoveredRow = session.id
            ui.renaming = session.id
        }
        panel.makeKeyAndOrderFront(nil)
        Debug.log("rename \(session.title)")
        // Select the whole title once the field has focus, so typing replaces it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commitRename() { finishRename(commit: true) }
    private func cancelRename() { finishRename(commit: false) }

    private func finishRename(commit: Bool, restoreFocus: Bool = true) {
        guard let id = ui.renaming else { return }
        let text = ui.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(ui.reduceMotion ? nil : .easeOut(duration: 0.15)) { ui.renaming = nil }
        if commit, let session = store.session(id: id) {
            Debug.log("rename commit \"\(text)\"")
            if text.isEmpty {
                Actions.renameWithAI(session)
            } else if text != session.title {
                Actions.rename(session, to: text)
            }
        }
        guard renameTookFocus else { return }
        renameTookFocus = false
        panel?.allowsKey = false
        let app = previousApp
        previousApp = nil
        relinquishKeyFocus(reactivating: restoreFocus ? app : nil)
        handleMouse()
    }

    // MARK: Debugging (TABBY_ISLAND_DEBUG=1)

    func debugState() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        return "expanded=\(ui.expanded) keyboard=\(ui.keyboard) key=\(panel?.isKeyWindow ?? false) " +
            "active=\(NSApp.isActive) front=\(front) mode=\(ui.mode.rawValue) selected=\(ui.hoveredRow ?? "-") " +
            "announcement=\(ui.announcement?.title ?? "-") queued=\(announcements.count) " +
            "renaming=\(ui.renaming.map { _ in "\"" + ui.renameText + "\"" } ?? "-") allowsKey=\(panel?.allowsKey ?? false) " +
            "hotkeys=\(HotkeyCenter.shared.isEnabled) config=\(config)\n" + watermark.debugState()
    }

    func postKey(code: UInt16, characters: String) {
        guard let panel, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
