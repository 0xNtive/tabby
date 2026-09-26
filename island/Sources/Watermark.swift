import AppKit

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

/// Draws each Terminal.app session's topic, large and faint, over its window: a click-through
/// window kept directly above the session's own. It follows the window by asking the window
/// server where it is: 4× a second while Terminal is in front, once a second otherwise, and at
/// once on clicks, app switches and desktop changes. While a window moves or resizes, its
/// watermark fades out and returns when the window settles.
@MainActor
final class WatermarkController {
    @MainActor
    private final class Overlay {
        let window = WatermarkWindow()
        let view = WatermarkView()
        /// The Terminal window's bounds when last seen, and since when they've held.
        var bounds: CGRect?
        var changedAt = Date.distantPast
        var shown = false

        init() {
            window.contentView = view
        }
    }

    private struct Target: Equatable {
        var text: String
        var tint: NSColor
    }

    private let terminalBundle = "com.apple.Terminal"
    private var settings = WatermarkSettings()
    private var targets: [Int: Target] = [:]
    private var overlays: [Int: Overlay] = [:]
    /// Every Terminal window the store knows (session tabs or not), and those already asked about.
    private var knownWindows = Set<Int>()
    private var askedAbout = Set<Int>()
    private var terminalPid: (pid: Int?, at: Date) = (nil, .distantPast)
    private var timer: Timer?
    private var lastTick = Date.distantPast
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// A Terminal window showed up that the store can't place yet (a tab moved to its own window).
    var onUnknownWindow: (() -> Void)?

    private var active: Bool { settings.enabled && !targets.isEmpty }

    func apply(_ settings: WatermarkSettings) {
        guard settings != self.settings else { return }
        let restyle = settings.size != self.settings.size || settings.opacity != self.settings.opacity ||
            settings.color != self.settings.color || settings.position != self.settings.position
        self.settings = settings
        if restyle { overlays.values.forEach { $0.view.settings = settings } }
        refreshActivity()
    }

    func update(_ snapshot: StoreSnapshot, color: (IslandSession) -> NSColor) {
        var next: [Int: Target] = [:]
        for session in snapshot.sessions where !session.disabled {
            guard let id = session.windowId else { continue }
            next[id] = Target(text: session.title, tint: color(session))
        }
        knownWindows = snapshot.terminalWindowIds
        guard next != targets else { return }
        targets = next
        for (id, target) in targets {
            guard let overlay = overlays[id] else { continue }
            overlay.view.text = target.text
            overlay.view.tint = target.tint
        }
        refreshActivity()
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
        var settling = false

        for (id, target) in targets {
            let overlay = overlays[id] ?? makeOverlay(id, target)
            let mine = windows[overlay.window.windowNumber]
            guard let seen = windows[id] else {
                // Not on screen: a background tab, minimized, closed or on another desktop. If the
                // overlay is on this desktop, its window isn't: hide it. Else both are elsewhere
                // (and it's still in place when you come back).
                if overlay.window.isVisible, mine != nil {
                    overlay.window.orderOut(nil)
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
                overlay.window.orderOut(nil)   // it belongs to another desktop: order it in here
                overlay.window.order(.above, relativeTo: id)
            } else if mine!.index + 1 != seen.index {
                overlay.window.order(.above, relativeTo: id)
            }
        }
        for (id, overlay) in overlays where targets[id] == nil {
            overlay.window.orderOut(nil)
            overlays[id] = nil
        }
        noticeUnknownWindows(windows)

        let terminalFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminalBundle
        schedule(after: settling ? 0.1 : (terminalFront ? 0.25 : 1.0))
    }

    /// A Terminal window on screen that no known tab lives in: a tab just moved into its own
    /// window (tiling does that). Ask the store to look again, once per window.
    private func noticeUnknownWindows(_ windows: [Int: WindowServer.Entry]) {
        if Date().timeIntervalSince(terminalPid.at) > 5 {
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: terminalBundle).first?.processIdentifier
            terminalPid = (pid.map(Int.init), Date())
        }
        guard let pid = terminalPid.pid else { return }
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
        overlay.window.setFrame(WindowServer.cocoaFrame(bounds), display: false)
        // An overlay left on another desktop is ordered out first, so it's ordered in on this one.
        if !onThisDesktop { overlay.window.orderOut(nil) }
        overlay.window.order(.above, relativeTo: id)
        overlay.shown = true
        fade(overlay, in: true, reduceMotion: reduceMotion)
    }

    private func fade(_ overlay: Overlay, in visible: Bool, reduceMotion: Bool) {
        overlay.shown = visible
        let target: CGFloat = visible ? 1 : 0
        guard !reduceMotion else {
            overlay.window.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.28 : 0.12
            overlay.window.animator().alphaValue = target
        }
    }

    private func removeAll() {
        for overlay in overlays.values { overlay.window.orderOut(nil) }
        overlays = [:]
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
            let above: String
            if let mine = windows[overlay.window.windowNumber], let target = windows[id] {
                above = mine.index + 1 == target.index ? "directly above" : "at \(mine.index), window at \(target.index)"
            } else {
                above = windows[id] == nil ? "window off screen" : "overlay off screen"
            }
            return "  window \(id) “\(targets[id]?.text ?? "?")” shown=\(overlay.shown) alpha=\(String(format: "%.2f", overlay.window.alphaValue)) " +
                "frame=\(NSStringFromRect(overlay.window.frame)) overlay=\(overlay.window.windowNumber) \(above)"
        }
        return "watermark enabled=\(settings.enabled) targets=\(targets.count) overlays=\(overlays.count) " +
            "active=\(NSApp.isActive)\n" + rows.sorted().joined(separator: "\n")
    }
}
