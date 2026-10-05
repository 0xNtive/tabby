import AppKit
import ApplicationServices

// MARK: - Settings

enum WatermarkSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// The tallest a line may be, as a share of the window's height.
    var scale: CGFloat {
        switch self {
        case .small: return 0.12
        case .medium: return 0.19
        case .large: return 0.28
        }
    }
}

enum WatermarkColor: String, CaseIterable, Identifiable, Sendable {
    case session, neutral

    var id: String { rawValue }
    var title: String { self == .session ? "Session color" : "Neutral" }
}

enum WatermarkPosition: String, CaseIterable, Identifiable, Sendable {
    case top, center, bottom

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// `watermark`, `watermarkOpacity` (percent), `watermarkSize`, `watermarkColor`, `watermarkPosition`.
struct WatermarkSettings: Equatable, Sendable {
    var enabled = true
    /// Percent.
    var opacity: Double = 18
    var size: WatermarkSize = .medium
    var color: WatermarkColor = .session
    var position: WatermarkPosition = .center

    static let opacityRange: ClosedRange<Double> = 3...40

    init() {}

    init(raw: [String: ConfigValue]) {
        enabled = raw["watermark"]?.bool ?? true
        if let value = raw["watermarkOpacity"]?.number, value.isFinite, value > 0 {
            // 0.12 and 12 both mean 12 %.
            opacity = min(max(value < 1 ? value * 100 : value, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        }
        size = raw["watermarkSize"]?.string.flatMap { WatermarkSize(rawValue: $0.lowercased()) } ?? .medium
        color = raw["watermarkColor"]?.string.flatMap { WatermarkColor(rawValue: $0.lowercased()) } ?? .session
        position = raw["watermarkPosition"]?.string.flatMap { WatermarkPosition(rawValue: $0.lowercased()) } ?? .center
    }

    /// The color a session's watermark is drawn in, before opacity.
    func tint(for session: IslandSession, themes: [ThemeInfo], globalTheme: String?) -> NSColor {
        let theme = themes.first { $0.id == (session.theme ?? globalTheme) }
        let hex = color == .session ? (session.cursorHex ?? session.accentHex ?? session.dotHex) : theme?.fg
        return NSColor(hexString: hex) ?? NSColor(white: 0.92, alpha: 1)
    }
}

// MARK: - Drawing

/// The watermark text, as large as fits: shared by the overlays, the Settings preview and snapshots.
final class WatermarkView: NSView {
    var text = "" { didSet { if text != oldValue { invalidate() } } }
    var tint: NSColor = .white { didSet { if tint != oldValue { invalidate() } } }
    var settings = WatermarkSettings() { didSet { if settings != oldValue { invalidate() } } }
    /// Kept clear at the top: a window's title bar and tab bar.
    var topInset: CGFloat = 44 { didSet { if topInset != oldValue { invalidate() } } }

    private var cache: (size: CGSize, string: NSAttributedString, rect: CGRect)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func invalidate() {
        cache = nil
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if cache?.size != newSize { invalidate() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if cache == nil || cache?.size != bounds.size {
            cache = Self.layout(text, tint: tint, settings: settings, in: bounds, topInset: topInset)
                .map { (bounds.size, $0.string, $0.rect) }
        }
        guard let cache else { return }
        cache.string.draw(with: cache.rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    static func font(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .heavy)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }

    private static func attributed(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.88
        return NSAttributedString(string: text, attributes: [
            .font: font(size), .foregroundColor: color, .paragraphStyle: paragraph, .kern: -size * 0.02,
        ])
    }

    /// The largest size at which `text` fits in three lines without breaking a word, placed in
    /// `bounds` (flipped: top-left origin).
    static func layout(_ text: String, tint: NSColor, settings: WatermarkSettings, in bounds: CGRect,
                       topInset: CGFloat) -> (string: NSAttributedString, rect: CGRect)? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let area = CGRect(x: bounds.minX + 20, y: bounds.minY + topInset,
                          width: bounds.width - 40, height: bounds.height - topInset - 20)
        guard !words.isEmpty, area.width > 60, area.height > 40 else { return nil }
        let clean = words.joined(separator: " ")
        let color = tint.withAlphaComponent(CGFloat(settings.opacity / 100))
        let maxWidth = area.width * 0.9
        let maxHeight = area.height * (settings.position == .center ? 0.84 : 0.56)
        let longest = words.max { $0.count < $1.count } ?? clean
        let layoutManager = NSLayoutManager()

        func measure(_ size: CGFloat) -> CGSize? {
            let string = attributed(clean, size: size, color: color)
            let box = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
            let line = layoutManager.defaultLineHeight(for: font(size)) * 0.88
            let word = attributed(longest, size: size, color: color).size().width
            guard box.height <= maxHeight, box.height <= line * 3.4, word <= maxWidth else { return nil }
            return CGSize(width: ceil(box.width), height: ceil(box.height))
        }

        var low: CGFloat = 10
        var high = min(area.height * settings.size.scale, 260)
        guard high > low, var best = measure(low) else { return nil }
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if let size = measure(mid) {
                low = mid
                best = size
            } else {
                high = mid
            }
        }
        let size = low.rounded(.down)
        let box = measure(size) ?? best
        let y: CGFloat
        switch settings.position {
        case .top: y = area.minY + area.height * 0.06
        case .center: y = area.midY - box.height / 2
        case .bottom: y = area.maxY - area.height * 0.16 - box.height
        }
        let rect = CGRect(x: area.midX - maxWidth / 2, y: y.rounded(), width: maxWidth, height: box.height + 2)
        return (attributed(clean, size: size, color: color), rect)
    }
}

// MARK: - Overlay window

/// Transparent, click-through, never key: only ever ordered directly above a Terminal window.
final class WatermarkWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        // Stays on the desktop it was ordered in (like the Terminal window under it), can join a
        // full-screen window's desktop, and never shows up in ⌘`.
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// On-screen windows at the normal level, front to back, from the window server. Needs no
/// Screen Recording permission: only numbers, owners and bounds are read, never titles.
enum WindowServer {
    struct Entry {
        let index: Int
        let pid: Int
        /// Top-left origin, the primary display's top-left corner at (0, 0).
        let bounds: CGRect
    }

    static func onScreen() -> [Int: Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [Int: Entry] = [:]
        var index = 0
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int else { continue }
            var rect = CGRect.zero
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary {
                _ = CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect)
            }
            out[number] = Entry(index: index, pid: info[kCGWindowOwnerPID as String] as? Int ?? 0, bounds: rect)
            index += 1
        }
        return out
    }

    /// Window-server bounds → AppKit screen coordinates (bottom-left origin).
    @MainActor
    static func cocoaFrame(_ bounds: CGRect) -> NSRect {
        let primary = NSScreen.screens.first?.frame.height ?? bounds.maxY
        return NSRect(x: bounds.minX, y: primary - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

// MARK: - Controller

/// Draws over each Terminal.app session's window: its topic, large and faint (the watermark,
/// click-through), or, in focus mode while Claude works there, an opaque cover (FocusCover.swift).
/// Each is a window kept directly above the session's own. It follows the window by asking the
/// window server where it is: 4× a second while Terminal is in front, once a second otherwise,
/// and at once on clicks, app switches and desktop changes. While a window moves or resizes,
/// what's over it fades out and returns when the window settles.
@MainActor
final class WatermarkController {
    /// What's over a Terminal window right now.
    private enum Presentation {
        case none, watermark, cover
    }

    @MainActor
    private final class Overlay {
        let window = WatermarkWindow()
        let view = WatermarkView()
        /// Focus mode's cover, made the first time it's needed.
        private(set) var coverWindow: FocusCoverWindow?
        var presentation = Presentation.none
        /// The Terminal window's bounds when last seen, and since when they've held.
        var bounds: CGRect?
        var changedAt = Date.distantPast
        var shown = false

        init() {
            window.contentView = view
        }

        var cover: FocusCoverWindow {
            if let coverWindow { return coverWindow }
            let made = FocusCoverWindow()
            coverWindow = made
            return made
        }

        /// The window that presents it, if any.
        var current: NSWindow? {
            switch presentation {
            case .none: return nil
            case .watermark: return window
            case .cover: return cover
            }
        }
    }

    private struct Target: Equatable {
        var text: String
        var tint: NSColor
        var status: SessionStatus
        /// Focus mode's cover for this window (focus mode on), shown while FocusRule says so.
        var cover: FocusCoverContent?
    }

    private let terminalBundle = "com.apple.Terminal"
    private var settings = WatermarkSettings()
    private var focusMode = false
    /// Covers stay when it's your turn (`focusIdle`).
    private var focusIdle = false
    /// Spins the covers' spinners (and keeps their times current) while any cover shows.
    private var animation: Timer?
    private var animationInterval: TimeInterval = 0
    private var animationStill = false
    private var targets: [Int: Target] = [:]
    private var overlays: [Int: Overlay] = [:]
    /// Every Terminal window the store knows (session tabs or not), and those already asked about.
    private var knownWindows = Set<Int>()
    /// Whether each window showed a tab bar, at the bounds it had when asked.
    private var tabBarCache: [Int: (bounds: CGRect, tabs: Bool)] = [:]
    private var askedAbout = Set<Int>()
    private var terminalPid: (pid: Int?, at: Date) = (nil, .distantPast)
    private var timer: Timer?
    private var lastTick = Date.distantPast
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// A Terminal window showed up that the store can't place yet (a tab moved to its own window).
    var onUnknownWindow: (() -> Void)?
    /// A cover was clicked: open that session (its session id).
    var onCoverClick: ((String) -> Void)?

    private var active: Bool { (settings.enabled || focusMode) && !targets.isEmpty }

    func apply(_ settings: WatermarkSettings, focusMode: Bool = false, focusIdle: Bool = false) {
        guard settings != self.settings || focusMode != self.focusMode || focusIdle != self.focusIdle else { return }
        let restyle = settings.size != self.settings.size || settings.opacity != self.settings.opacity ||
            settings.color != self.settings.color || settings.position != self.settings.position
        self.settings = settings
        self.focusMode = focusMode
        self.focusIdle = focusIdle
        if restyle { overlays.values.forEach { $0.view.settings = settings } }
        refreshActivity()
    }

    func update(_ snapshot: StoreSnapshot, color: (IslandSession) -> NSColor) {
        var next: [Int: Target] = [:]
        let now = Date()
        for session in snapshot.sessions where !session.disabled {
            guard let id = session.windowId else { continue }
            let cover = focusMode
                ? FocusCoverContent.make(session, themes: snapshot.themes, globalTheme: snapshot.globalThemeId, now: now)
                : nil
            guard settings.enabled || cover != nil else { continue }
            next[id] = Target(text: session.title, tint: color(session), status: session.status, cover: cover)
        }
        if snapshot.terminalWindowIds != knownWindows {
            // A tab joined or left a window: covers measure the tab bar again.
            tabBarCache.removeAll()
            for overlay in overlays.values where overlay.presentation == .cover && overlay.shown { overlay.bounds = nil }
        }
        knownWindows = snapshot.terminalWindowIds
        guard next != targets else { return }
        let statusChanged = next.contains { id, target in targets[id]?.status != target.status }
        targets = next
        for (id, target) in targets {
            guard let overlay = overlays[id] else { continue }
            overlay.view.text = target.text
            overlay.view.tint = target.tint
            if let cover = target.cover, overlay.coverWindow != nil { overlay.cover.cover.content = cover }
        }
        refreshActivity()
        // Claude finished or needs you: open its window now, not at the next round.
        if statusChanged { poke() }
    }

    /// Starts or stops following windows, and ticks now.
    private func refreshActivity() {
        if active {
            startObserving()
            poke()
        } else {
            timer?.invalidate()
            timer = nil
            stopObserving()
            removeAll()
            animate(every: nil)
        }
    }

    /// Checks the windows soon (coalesces bursts of clicks and drags).
    func poke(after delay: TimeInterval = 0.02) {
        guard active else { return }
        if let timer, timer.fireDate.timeIntervalSinceNow <= delay { return }
        schedule(after: delay)
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        timer = nil
        guard active else { return removeAll() }
        let now = Date()
        lastTick = now
        let windows = WindowServer.onScreen()
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let terminalActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminalBundle
        let frontTerminalWindow = focusMode ? self.frontTerminalWindow(windows) : nil
        var settling = false

        for (id, target) in targets {
            let overlay = overlays[id] ?? makeOverlay(id, target)
            let covered = target.cover != nil &&
                FocusRule.covers(status: target.status, windowIsFront: id == frontTerminalWindow, terminalActive: terminalActive,
                                 idle: focusIdle)
            let wanted: Presentation = covered ? .cover : settings.enabled ? .watermark : .none
            if wanted != overlay.presentation { present(overlay, wanted, id: id, target: target, reduceMotion: reduceMotion) }
            guard let window = overlay.current else { continue }
            let mine = windows[window.windowNumber]
            guard let seen = windows[id] else {
                // Not on screen: a background tab, minimized, closed or on another desktop. If the
                // overlay is on this desktop, its window isn't: hide it. Else both are elsewhere
                // (and it's still in place when you come back).
                if window.isVisible, mine != nil {
                    window.orderOut(nil)
                    overlay.shown = false
                    overlay.bounds = nil
                }
                continue
            }
            if overlay.bounds == nil, !mouseDown {
                // Just appeared (a tab brought forward, a window restored): show it right away.
                overlay.bounds = seen.bounds
                show(overlay, above: id, bounds: seen.bounds, onThisDesktop: mine != nil, reduceMotion: reduceMotion)
                continue
            }
            if overlay.bounds != seen.bounds {
                // New, moving or resizing: out of the way until the window holds still.
                overlay.bounds = seen.bounds
                overlay.changedAt = now
                if overlay.shown { fade(overlay, in: false, reduceMotion: reduceMotion) }
                settling = true
                continue
            }
            if !overlay.shown {
                if now.timeIntervalSince(overlay.changedAt) >= 0.3, !mouseDown {
                    show(overlay, above: id, bounds: seen.bounds, onThisDesktop: mine != nil, reduceMotion: reduceMotion)
                } else {
                    settling = true
                }
                continue
            }
            // Shown: keep it directly above its window (clicking a window raises it over the overlay).
            if mine == nil {
                window.orderOut(nil)   // it belongs to another desktop: order it in here
                window.order(.above, relativeTo: id)
            } else if mine!.index + 1 != seen.index {
                window.order(.above, relativeTo: id)
            }
        }
        for (id, overlay) in overlays where targets[id] == nil {
            overlay.window.orderOut(nil)
            overlay.coverWindow?.orderOut(nil)
            overlays[id] = nil
        }
        noticeUnknownWindows(windows)
        animateCovers(reduceMotion: reduceMotion)

        schedule(after: settling ? 0.1 : (terminalActive ? 0.25 : 1.0))
    }

    /// Terminal's frontmost session window on this desktop (the one you'd type into). Only
    /// windows that show a tab count: a sheet or Terminal's own Settings in front leaves the window
    /// under it as the one you're in.
    private func frontTerminalWindow(_ windows: [Int: WindowServer.Entry]) -> Int? {
        guard let pid = terminalProcess() else { return nil }
        return windows.filter { $0.value.pid == pid && knownWindows.contains($0.key) }.min { $0.value.index < $1.value.index }?.key
    }

    private func terminalProcess() -> Int? {
        if Date().timeIntervalSince(terminalPid.at) > 5 {
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: terminalBundle).first?.processIdentifier
            terminalPid = (pid.map(Int.init), Date())
        }
        return terminalPid.pid
    }

    /// Switches what's over a window (watermark ↔ cover ↔ nothing). The new one shows at once
    /// if the window's on screen (else when it comes back).
    private func present(_ overlay: Overlay, _ next: Presentation, id: Int, target: Target, reduceMotion: Bool) {
        if let old = overlay.current, overlay.shown || old.isVisible {
            if overlay.presentation == .cover {
                // Lifting the cover: out of the mouse's way at once, then a quick fade.
                old.ignoresMouseEvents = true
                if reduceMotion {
                    old.alphaValue = 0
                    old.orderOut(nil)
                } else {
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.16
                        old.animator().alphaValue = 0
                    }, completionHandler: { [weak old] in
                        MainActor.assumeIsolated {
                            guard let old, old.alphaValue == 0 else { return }
                            old.orderOut(nil)
                        }
                    })
                }
            } else {
                old.alphaValue = 0
                old.orderOut(nil)
            }
        }
        overlay.presentation = next
        overlay.shown = false
        overlay.bounds = nil
        if next == .cover, let content = target.cover {
            let cover = overlay.cover
            cover.cover.content = content
            cover.ignoresMouseEvents = false
            cover.cover.onClick = { [weak self] in
                // The session this window shows now (another can take its place while covered).
                self?.onCoverClick?(self?.targets[id]?.cover?.sessionId ?? content.sessionId)
                self?.poke(after: 0.3)
            }
        }
    }

    /// A Terminal window on screen that no known tab lives in: a tab just moved into its own
    /// window (tiling does that). Ask the store to look again, once per window.
    private func noticeUnknownWindows(_ windows: [Int: WindowServer.Entry]) {
        guard let pid = terminalProcess() else { return }
        let unknown = windows.filter { number, entry in
            entry.pid == pid && entry.bounds.width > 150 && entry.bounds.height > 100 &&
                !knownWindows.contains(number) && !askedAbout.contains(number)
        }
        guard !unknown.isEmpty else { return }
        askedAbout.formUnion(unknown.keys)
        Debug.log("watermark: unknown Terminal windows \(unknown.keys.sorted())")
        onUnknownWindow?()
    }

    private func makeOverlay(_ id: Int, _ target: Target) -> Overlay {
        let overlay = Overlay()
        overlay.view.text = target.text
        overlay.view.tint = target.tint
        overlay.view.settings = settings
        overlays[id] = overlay
        return overlay
    }

    private func show(_ overlay: Overlay, above id: Int, bounds: CGRect, onThisDesktop: Bool, reduceMotion: Bool) {
        guard let window = overlay.current else { return }
        var frame = WindowServer.cocoaFrame(bounds)
        if overlay.presentation == .cover {
            // Only the content: the title bar (and tab bar) stay yours to click.
            let fullScreen = TerminalChrome.isFullScreen(frame, screens: NSScreen.screens.map { ($0.frame, $0.safeAreaInsets.top) })
            let inset = (fullScreen ? 0 : TerminalChrome.titleBar) + (showsTabBar(id, bounds: bounds) ? TerminalChrome.tabBar : 0)
            frame.size.height = max(0, frame.height - inset)
            overlay.cover.cover.cornerRadius = fullScreen ? 0 : TerminalChrome.cornerRadius
        }
        window.setFrame(frame, display: false)
        // An overlay left on another desktop is ordered out first, so it's ordered in on this one.
        if !onThisDesktop { window.orderOut(nil) }
        window.order(.above, relativeTo: id)
        overlay.shown = true
        fade(overlay, in: true, reduceMotion: reduceMotion)
    }

    /// Whether Terminal's window `id` (at `bounds`) shows a tab bar, so a cover stays below it.
    /// Accessibility sees the tab bar itself (an AXTabGroup in the window) once the island is
    /// allowed it; before that, another Terminal window with exactly this frame is taken for a
    /// tab of the same window (reliable until a tab group is moved).
    private func showsTabBar(_ id: Int, bounds: CGRect) -> Bool {
        if let cached = tabBarCache[id], cached.bounds == bounds { return cached.tabs }
        let seen = AXIsProcessTrusted() ? terminalProcess().flatMap { Self.axShowsTabBar(pid: $0, bounds: bounds) } : nil
        let tabs = seen ?? sameFrameWindow(id, bounds: bounds)
        tabBarCache[id] = (bounds, tabs)
        return tabs
    }

    /// Terminal's window at `bounds` (top-left origin), asked through Accessibility; nil when
    /// no window there answers.
    nonisolated static func axShowsTabBar(pid: Int, bounds: CGRect) -> Bool? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(app, 0.2)
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var out: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success ? out : nil
        }
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for window in windows {
            var origin = CGPoint.zero
            var size = CGSize.zero
            guard let position = value(window, kAXPositionAttribute), let extent = value(window, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(extent) == AXValueGetTypeID(),
                  AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(extent as! AXValue, .cgSize, &size),
                  abs(origin.x - bounds.minX) < 2, abs(origin.y - bounds.minY) < 2,
                  abs(size.width - bounds.width) < 2, abs(size.height - bounds.height) < 2 else { continue }
            let children = value(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return children.contains { value($0, kAXRoleAttribute) as? String == kAXTabGroupRole as String }
        }
        return nil
    }

    /// Another of Terminal's windows (a tab in the background) has exactly this frame. The window
    /// server takes the ids as raw CGWindowID values, not NSNumbers.
    private func sameFrameWindow(_ id: Int, bounds: CGRect) -> Bool {
        var values = knownWindows.subtracting([id]).map { UnsafeRawPointer(bitPattern: UInt(CGWindowID($0))) }
        guard !values.isEmpty else { return false }
        let array = values.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) }
        guard let array, let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return false }
        return list.contains { info in
            var rect = CGRect.zero
            guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &rect) else { return false }
            return rect == bounds
        }
    }

    private func fade(_ overlay: Overlay, in visible: Bool, reduceMotion: Bool) {
        overlay.shown = visible
        guard let window = overlay.current else { return }
        let target: CGFloat = visible ? 1 : 0
        guard !reduceMotion else {
            window.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.28 : 0.12
            window.animator().alphaValue = target
        }
    }

    private func removeAll() {
        for overlay in overlays.values {
            overlay.window.orderOut(nil)
            overlay.coverWindow?.orderOut(nil)
        }
        overlays = [:]
    }

    // MARK: Focus mode's spinners

    /// A cover someone could see: shown, and not on another desktop or buried under windows.
    private static func coverVisible(_ overlay: Overlay) -> Bool {
        overlay.presentation == .cover && overlay.shown && overlay.coverWindow?.occlusionState.contains(.visible) == true
    }

    /// One timer for every cover, only while one shows: 10 frames a second while Claude works
    /// under one (a once-a-second clock with still spinners under Reduce Motion); twice a minute
    /// when every cover says "Your turn", to keep "done 12m ago" current.
    private func animateCovers(reduceMotion: Bool) {
        let visible = overlays.values.filter(Self.coverVisible)
        if visible.isEmpty { return animate(every: nil) }
        let working = visible.contains { $0.cover.cover.content?.yourTurn == false }
        animate(every: working ? (reduceMotion ? 1 : 0.1) : 30, still: reduceMotion)
    }

    private func animate(every interval: TimeInterval?, still: Bool = false) {
        guard let interval else {
            animation?.invalidate()
            animation = nil
            return
        }
        if animation != nil, interval == animationInterval, still == animationStill { return }
        animation?.invalidate()
        animationInterval = interval
        animationStill = still
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for overlay in self.overlays.values where Self.coverVisible(overlay) {
                    overlay.cover.cover.still = self.animationStill
                    overlay.cover.cover.advance()
                }
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    // MARK: Events that move windows

    private func startObserving() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poke() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poke(after: 0.35) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poke(after: 0.2) }
        })
        // Global mouse events need no permission: a click can raise a Terminal window over its
        // watermark, and a drag moves it.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .leftMouseDragged, Date().timeIntervalSince(self.lastTick) < 0.06 { return }
                self.poke(after: type == .leftMouseUp ? 0.05 : 0.02)
            }
        }
    }

    private func stopObserving() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // MARK: Debugging

    func debugState() -> String {
        let windows = WindowServer.onScreen()
        let rows = overlays.map { id, overlay -> String in
            let window = overlay.current ?? overlay.window
            let above: String
            if let mine = windows[window.windowNumber], let target = windows[id] {
                above = mine.index + 1 == target.index ? "directly above" : "at \(mine.index), window at \(target.index)"
            } else {
                above = windows[id] == nil ? "window off screen" : "overlay off screen"
            }
            return "  window \(id) “\(targets[id]?.text ?? "?")” \(overlay.presentation) shown=\(overlay.shown) " +
                "alpha=\(String(format: "%.2f", window.alphaValue)) frame=\(NSStringFromRect(window.frame)) " +
                "overlay=\(window.windowNumber) \(above)"
        }
        return "watermark enabled=\(settings.enabled) focusMode=\(focusMode) focusIdle=\(focusIdle) targets=\(targets.count) " +
            "overlays=\(overlays.count) animating=\(animation != nil) active=\(NSApp.isActive)\n" +
            rows.sorted().joined(separator: "\n")
    }
}
