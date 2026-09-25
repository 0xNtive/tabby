import AppKit
import SwiftUI

// MARK: - Window

/// Borderless, non-activating panel that floats above the menu bar on every Space.
final class IslandPanel: NSPanel {
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

    // Never steal keyboard focus from the terminal.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Clicks work on the first try even though the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Geometry & UI state

struct IslandGeometry: Equatable {
    var hasNotch = false
    var notchWidth: CGFloat = 0
    var barHeight: CGFloat = 32
    var panelSize = CGSize(width: 560, height: 680)

    static let expandedWidth: CGFloat = 480

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
        let height = min(680, (frame.height * 0.8).rounded())
        geometry.panelSize = CGSize(width: 560, height: height)
        let rect = NSRect(x: (frame.midX - 280).rounded(), y: frame.maxY - height, width: 560, height: height)
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
    @Published var hoveredRow: String?
    @Published var geometry = IslandGeometry()
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var menuOpen = false
    var modalOpen = false
}

/// Callbacks from the SwiftUI tree back into the controller.
struct IslandActions {
    var islandFrame: @MainActor (CGRect) -> Void
    var rowFrames: @MainActor ([String: CGRect]) -> Void
    var viewport: @MainActor (CGRect) -> Void
    var expand: @MainActor () -> Void
    var tapRow: @MainActor (IslandSession) -> Void
    var sessionMenu: @MainActor (IslandSession) -> Void
    var themeAllMenu: @MainActor () -> Void
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
    private var islandFrame: CGRect = .zero
    private var rowFrames: [String: CGRect] = [:]
    private var viewport: CGRect = .zero
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var lastMouse = CGPoint(x: -1, y: -1)
    private var observers: [NSObjectProtocol] = []
    private(set) var isShown = false

    private let expandDelay = 0.12
    private let collapseDelay = 0.35

    init(store: SessionStore) {
        self.store = store
        buildPanel()
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
            expand: { [weak self] in self?.setExpanded(true) },
            tapRow: { [weak self] session in self?.focus(session) },
            sessionMenu: { [weak self] session in self?.showSessionMenu(session) },
            themeAllMenu: { [weak self] in self?.showThemeAllMenu() }
        )
        let host = IslandHostingView(rootView: IslandRootView(store: store, ui: ui, actions: actions))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: rect.size)
        host.autoresizingMask = [.width, .height]
        let panel = IslandPanel(contentRect: rect)
        panel.contentView = host
        self.panel = panel
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
                if expandWork == nil { scheduleExpand() }
            } else if moved {
                updateRowHover(point)
            }
        } else {
            expandWork?.cancel()
            expandWork = nil
            if ui.expanded {
                if !ui.menuOpen, !ui.modalOpen, collapseWork == nil { scheduleCollapse() }
            } else {
                setPolling(false)
            }
            if !ui.menuOpen, ui.hoveredRow != nil { setHoveredRow(nil) }
        }
    }

    private func updateRowHover(_ point: CGPoint) {
        guard !ui.menuOpen else { return }
        var hit: String?
        if viewport.isEmpty || viewport.contains(point) {
            hit = rowFrames.first { $0.value.contains(point) }?.key
        }
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
                guard !self.ui.menuOpen, !self.ui.modalOpen else { return }
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
        let animation: Animation = ui.reduceMotion
            ? .easeInOut(duration: 0.14)
            : (value ? .spring(response: 0.42, dampingFraction: 0.8) : .spring(response: 0.34, dampingFraction: 0.92))
        withAnimation(animation) {
            ui.expanded = value
            if !value { ui.hoveredRow = nil }
        }
        if !value { rowFrames = [:] }
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

    // MARK: Row actions

    private func focus(_ session: IslandSession) {
        setExpanded(false)
        Actions.focus(session)
    }

    private func showSessionMenu(_ session: IslandSession) {
        let menu = MenuFactory.shared.sessionMenu(for: session, store: store) { [weak self] in
            self?.promptRename(session)
        }
        popUp(menu)
    }

    private func showThemeAllMenu() {
        let menu = MenuFactory.shared.themeMenu(store: store, current: store.snapshot.globalThemeId) { id in
            Actions.setThemeAll(id)
        }
        popUp(menu)
    }

    private func popUp(_ menu: NSMenu) {
        ui.menuOpen = true
        collapseWork?.cancel()
        collapseWork = nil
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        ui.menuOpen = false
        handleMouse()
    }

    private func promptRename(_ session: IslandSession) {
        // Let the menu finish closing before running a modal alert.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ui.modalOpen = true
                let result = Dialogs.rename(current: session.title, project: session.project)
                self.ui.modalOpen = false
                switch result {
                case .rename(let name): Actions.rename(session, to: name)
                case .auto: Actions.renameWithAI(session)
                case .cancel: break
                }
                self.setExpanded(false)
            }
        }
    }
}
