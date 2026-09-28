import AppKit
import ApplicationServices
import Carbon

/// What Tabby Island needs from macOS, checked live while a window shows it (the onboarding,
/// Settings › Permissions), and every 20 s in the background until everything needed is allowed:
///
/// - **Accessibility:** tiling splits tabs into windows and takes windows out of full screen.
/// - **Automation of Terminal:** jumping to a tab, reading tab titles, and finding each
///   session's window for the watermark.
/// - **Automation of iTerm2:** jumping to a tab and reading tab titles there.
/// - **Automation of System Events:** tiling clicks Terminal's "Move Tab to New Window".
///
/// Only what the terminals in use need: a Mac that runs Claude in VS Code or Ghostty is asked
/// for nothing. Every change is written to ~/.claude/tabby/island-status.json, where
/// `tabby doctor` (and Claude, helping someone install) reads it.
@MainActor
final class PermissionCenter: ObservableObject {
    enum Status: Equatable {
        /// Not checked yet.
        case unknown
        /// macOS hasn't asked yet.
        case notAsked
        /// A macOS prompt or System Settings is open.
        case waiting
        case allowed
        case denied

        var granted: Bool { self == .allowed }
    }

    enum Target: String, CaseIterable, Identifiable, Sendable {
        case terminal = "com.apple.Terminal"
        case iTerm = "com.googlecode.iterm2"
        case systemEvents = "com.apple.systemevents"

        var id: String { rawValue }
        var name: String {
            switch self {
            case .terminal: return "Terminal"
            case .iTerm: return "iTerm2"
            case .systemEvents: return "System Events"
            }
        }
        /// Its key in island-status.json.
        var key: String {
            switch self {
            case .terminal: return "terminal"
            case .iTerm: return "iterm"
            case .systemEvents: return "systemEvents"
            }
        }
    }

    @Published private(set) var accessibility: Status = .unknown
    @Published private(set) var automation: [Target: Status] = [:]
    /// Terminal.app / iTerm2 are in use here: running, or where a known session runs.
    @Published private(set) var usesTerminal = true
    @Published private(set) var usesITerm = false
    /// Terminal just became controllable: the store can read its tabs now.
    var onTerminalAllowed: (() -> Void)?
    /// The terminals the island's sessions run in ("apple-terminal", "iterm2", …).
    var sessionTerms: () -> Set<String> = { [] }

    private var timer: Timer?
    private var background: Timer?
    /// What the status file says now (it's rewritten only when this changes).
    private var reported: [String: String]?
    private var watchers = 0
    private var accessibilityRequested = false
    private var asking = Set<Target>()
    private let fixed: Bool
    private let queue = DispatchQueue(label: "dev.tabby.island.permissions", qos: .userInitiated)
    nonisolated private static let rememberedKey = "automationAllowed"

    init() {
        fixed = false
    }

    /// Snapshot renders: a frozen state.
    init(accessibility: Status, automation: [Target: Status], usesTerminal: Bool = true, usesITerm: Bool = false) {
        fixed = true
        self.accessibility = accessibility
        self.automation = automation
        self.usesTerminal = usesTerminal
        self.usesITerm = usesITerm
    }

    /// Asked for at all on this Mac (see the type's comment).
    func isNeeded(_ target: Target) -> Bool {
        switch target {
        case .terminal, .systemEvents: return usesTerminal
        case .iTerm: return usesITerm
        }
    }

    var accessibilityNeeded: Bool { usesTerminal || usesITerm }
    var neededTargets: [Target] { Target.allCases.filter(isNeeded) }
    /// None of the terminals in use can be scripted: there's nothing to allow.
    var nothingNeeded: Bool { !accessibilityNeeded && neededTargets.isEmpty }

    var allGranted: Bool {
        (!accessibilityNeeded || accessibility.granted) && neededTargets.allSatisfy { status(of: $0).granted }
    }

    func status(of target: Target) -> Status { automation[target] ?? .unknown }

    /// A check at launch, then in the background: every 20 s while something needed is missing,
    /// every minute once all is allowed (which terminals are in use can change: Terminal opened
    /// after login, a first iTerm2 session). So `tabby doctor` sees a switch flipped in System
    /// Settings with no window open. The status file is only written when something changed.
    func startBackgroundChecks() {
        guard !fixed else { return }
        refresh()
        scheduleBackgroundCheck()
    }

    private func scheduleBackgroundCheck() {
        background?.invalidate()
        let interval: TimeInterval = allGranted && accessibility != .unknown ? 60 : 20
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.watchers == 0 { self.refresh() }
                self.scheduleBackgroundCheck()
            }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        background = timer
    }

    /// Something "Allow All" can still ask for. A "Don't Allow" isn't: macOS won't ask again,
    /// so that one is switched on in System Settings (the card's Open Settings).
    var canAskAll: Bool {
        (accessibilityNeeded && (accessibility == .notAsked || accessibility == .unknown))
            || neededTargets.contains { status(of: $0) == .notAsked || status(of: $0) == .unknown }
    }

    // MARK: Watching

    /// Checks every second while something shows the statuses.
    func startWatching() {
        watchers += 1
        refresh()
        guard timer == nil, !fixed else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !fixed else { return }
        let terms = sessionTerms()
        let terminal = Self.isRunning(.terminal) || terms.contains("apple-terminal")
        let iTerm = Self.isRunning(.iTerm) || terms.contains("iterm2")
        if usesTerminal != terminal { usesTerminal = terminal }
        if usesITerm != iTerm { usesITerm = iTerm }
        let trusted = AXIsProcessTrusted()
        let next: Status = trusted ? .allowed : (accessibilityRequested ? .waiting : .notAsked)
        if accessibility != next { accessibility = next }
        if trusted { accessibilityRequested = false }
        report()
        for target in Target.allCases where !asking.contains(target) {
            queue.async { [weak self] in
                let status = Self.determine(target, ask: false)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.settle(target, status) }
                }
            }
        }
    }

    /// `nil`: the app to control isn't running, so macOS can't say. Keep what was known.
    private func settle(_ target: Target, _ status: Status?) {
        guard !asking.contains(target) else { return }
        let known = status ?? (Self.remembered(target) ? .allowed : .notAsked)
        if automation[target] != known {
            automation[target] = known
            report()
        }
        if let status { Self.remember(target, status == .allowed) }
    }

    /// Writes the statuses for `tabby doctor` ("notNeeded" for what this Mac isn't asked for),
    /// only when they changed.
    private func report() {
        guard !fixed else { return }
        var permissions: [String: String] = [
            "accessibility": accessibilityNeeded ? Self.word(accessibility) : "notNeeded",
        ]
        for target in Target.allCases {
            permissions[target.key] = isNeeded(target) ? Self.word(status(of: target)) : "notNeeded"
        }
        guard permissions != reported else { return }
        reported = permissions
        IslandReport.write(["permissions": permissions])
    }

    nonisolated private static func word(_ status: Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .notAsked: return "notAsked"
        case .waiting: return "waiting"
        case .allowed: return "allowed"
        case .denied: return "denied"
        }
    }

    // MARK: Asking

    /// Clears an Accessibility entry an earlier build left (ad-hoc builds before 0.2.5 were
    /// signed by their own hash, so macOS kept showing them as allowed), then asks: macOS adds
    /// Tabby Island to the list and offers to open System Settings, where you switch it on.
    func requestAccessibility() {
        guard !fixed else { return }
        guard !AXIsProcessTrusted() else {
            accessibility = .allowed
            return
        }
        Self.resetEntries("Accessibility")
        accessibilityRequested = true
        accessibility = .waiting
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Asks macOS whether the island may control `target`: the system prompt shows the first
    /// time. System Events only runs on demand, so it's started (in the background) first.
    func requestAutomation(_ target: Target) {
        guard !fixed, !asking.contains(target) else { return }
        asking.insert(target)
        automation[target] = .waiting
        queue.async { [weak self] in
            // macOS only asks about an app that's running: start it first, in the background.
            Self.launch(target)
            let status = Self.determine(target, ask: true) ?? .notAsked
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.asking.remove(target)
                    self.automation[target] = status
                    self.report()
                    Self.remember(target, status == .allowed)
                    if target == .terminal, status == .allowed { self.onTerminalAllowed?() }
                }
            }
        }
    }

    /// One click for everything this Mac needs: each app's prompt in turn (each waits for your
    /// answer), then Accessibility last, since that one opens System Settings.
    func requestAll() {
        guard !fixed else { return }
        let targets = neededTargets.filter { (status(of: $0) == .notAsked || status(of: $0) == .unknown) && !asking.contains($0) }
        for target in targets {
            asking.insert(target)
            automation[target] = .waiting
        }
        let wantsAccessibility = accessibilityNeeded && !AXIsProcessTrusted() && (accessibility == .notAsked || accessibility == .unknown)
        queue.async { [weak self] in
            var results: [(Target, Status)] = []
            for target in targets {
                Self.launch(target)
                results.append((target, Self.determine(target, ask: true) ?? .notAsked))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (target, status) in results {
                        self.asking.remove(target)
                        self.automation[target] = status
                        Self.remember(target, status == .allowed)
                        if target == .terminal, status == .allowed { self.onTerminalAllowed?() }
                    }
                    self.report()
                    if wantsAccessibility { self.requestAccessibility() }
                }
            }
        }
    }

    /// Denied once, macOS won't ask again by itself. Each app has its own switch under Tabby
    /// Island in System Settings › Privacy & Security › Automation: open it there. (Resetting the
    /// island's Automation answers would also take back the ones you allowed.) The statuses are
    /// watched while a window shows them, so the card turns Allowed when you flip the switch.
    func askAgain(_ target: Target) {
        guard !fixed else { return }
        Self.openAutomationPane()
    }

    /// For the card or row of a denied app: where its switch is.
    static func deniedHint(_ target: Target) -> String {
        "Switch on “\(target.name)” under Tabby Island in System Settings › Privacy & Security › Automation."
    }

    static func openAccessibilityPane() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomationPane() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    // MARK: macOS

    nonisolated private static func determine(_ target: Target, ask: Bool) -> Status? {
        automationStatus(target.rawValue, ask: ask)
    }

    /// May the island send Apple events to the app with this bundle id? `nil` when it isn't
    /// running (macOS only answers for running apps). With `ask`, macOS shows its prompt if it
    /// hasn't asked yet; that call blocks until it's answered.
    nonisolated static func automationStatus(_ bundleId: String, ask: Bool) -> Status? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else { return nil }
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        let status = AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, AEEventClass(typeWildCard),
                                                           AEEventID(typeWildCard), ask)
        switch Int(status) {
        case Int(noErr): return .allowed
        case errAEEventNotPermitted: return .denied
        case errAEEventWouldRequireUserConsent: return .notAsked
        case procNotFound: return nil
        default: return .notAsked
        }
    }

    nonisolated static func isRunning(_ target: Target) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: target.rawValue).isEmpty
    }

    /// Starts the app without bringing it forward (System Events only runs on demand; Terminal or
    /// iTerm2 may simply be closed right now), and waits up to 4 s for it.
    nonisolated private static func launch(_ target: Target) {
        guard !isRunning(target),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.rawValue) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = target != .systemEvents
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<40 where !isRunning(target) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        // A freshly started app answers Apple events a moment after it shows up.
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// `tccutil reset <service> dev.tabby.island`: only the island's own entries.
    nonisolated static func resetEntries(_ service: String) {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "dev.tabby.island"]
        reset.standardOutput = FileHandle.nullDevice
        reset.standardError = FileHandle.nullDevice
        if (try? reset.run()) != nil { reset.waitUntilExit() }
    }

    /// The last answer per app, for when it isn't running (System Events quits when idle).
    nonisolated private static func remembered(_ target: Target) -> Bool {
        (UserDefaults.standard.dictionary(forKey: rememberedKey)?[target.rawValue] as? Bool) ?? false
    }

    nonisolated private static func remember(_ target: Target, _ allowed: Bool) {
        var map = UserDefaults.standard.dictionary(forKey: rememberedKey) ?? [:]
        map[target.rawValue] = allowed
        UserDefaults.standard.set(map, forKey: rememberedKey)
    }
}

/// ~/.claude/tabby/island-status.json: what the island knows about itself (version, screen,
/// permissions, whether you quit it), for `tabby doctor` and SessionStart. Merged, never replaced.
enum IslandReport {
    static var url: URL {
        ClaudePaths.tabby.appendingPathComponent("island-status.json")
    }

    static func write(_ patch: [String: Any]) {
        var json = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        for (key, value) in patch { json[key] = value }
        json["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        json["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        json["app"] = Bundle.main.bundlePath
        json["updatedAt"] = Int(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
