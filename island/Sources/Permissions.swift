import AppKit
import ApplicationServices
import Carbon

/// What Tabby Island needs from macOS, checked live while a window shows it (the onboarding,
/// Settings › Permissions):
///
/// - **Accessibility:** tiling splits tabs into windows and takes windows out of full screen.
/// - **Automation of Terminal:** jumping to a tab, reading tab titles, and finding each
///   session's window for the watermark.
/// - **Automation of System Events:** tiling clicks Terminal's "Move Tab to New Window".
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
        case systemEvents = "com.apple.systemevents"

        var id: String { rawValue }
        var name: String { self == .terminal ? "Terminal" : "System Events" }
    }

    @Published private(set) var accessibility: Status = .unknown
    @Published private(set) var automation: [Target: Status] = [:]

    private var timer: Timer?
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
    init(accessibility: Status, automation: [Target: Status]) {
        fixed = true
        self.accessibility = accessibility
        self.automation = automation
    }

    var allGranted: Bool {
        accessibility.granted && Target.allCases.allSatisfy { status(of: $0).granted }
    }

    func status(of target: Target) -> Status { automation[target] ?? .unknown }

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
        let trusted = AXIsProcessTrusted()
        let next: Status = trusted ? .allowed : (accessibilityRequested ? .waiting : .notAsked)
        if accessibility != next { accessibility = next }
        if trusted { accessibilityRequested = false }
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
        if automation[target] != known { automation[target] = known }
        if let status { Self.remember(target, status == .allowed) }
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
            if target == .systemEvents { Self.launchSystemEvents() }
            let status = Self.determine(target, ask: true) ?? .notAsked
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.asking.remove(target)
                    self.automation[target] = status
                    Self.remember(target, status == .allowed)
                }
            }
        }
    }

    /// Denied once, macOS won't ask again: forget the island's Automation answers, then ask.
    func askAgain(_ target: Target) {
        Self.resetEntries("AppleEvents")
        requestAutomation(target)
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

    /// `nil` when the target isn't running (macOS only answers for running apps).
    nonisolated private static func determine(_ target: Target, ask: Bool) -> Status? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: target.rawValue).isEmpty else { return nil }
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: target.rawValue)
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

    nonisolated private static func launchSystemEvents() {
        let id = Target.systemEvents.rawValue
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app"),
                                           configuration: configuration)
        for _ in 0..<40 where NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
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
