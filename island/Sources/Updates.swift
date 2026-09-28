import AppKit
import SwiftUI

/// tabby's updates as the island sees them: what the last check found, an update in progress,
/// and starting one. The CLI does the work (`tabby update`, detached, so it carries on while the
/// island restarts on the new version). Both sides meet in ~/.claude/tabby: update-check.json
/// (the last check) and update-state.json (running, done, current, failed).
@MainActor
final class UpdateCenter: ObservableObject {
    struct Info: Equatable {
        var current: String?
        var latest: String?
        var available = false
        var checkedAt: Date?
        var error: String?
    }

    enum Phase: Equatable {
        case idle, checking
        case updating(String)
        case failed(String)

        var busy: Bool {
            switch self {
            case .checking, .updating: return true
            default: return false
            }
        }
    }

    @Published private(set) var info = Info()
    @Published private(set) var phase: Phase = .idle
    /// Says something in the island: (text, SF Symbol).
    var announce: ((String, String) -> Void)?

    private var checkTimer: Timer?
    private var pollTimer: Timer?
    private let fixed: Bool
    private static let checkEvery: TimeInterval = 6 * 3600
    private static let announcedKey = "announcedUpdate"

    init() { fixed = false }

    /// Snapshot renders: a frozen state.
    init(info: Info, phase: Phase = .idle) {
        fixed = true
        self.info = info
        self.phase = phase
    }

    private var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/tabby", isDirectory: true)
    }

    // MARK: Lifecycle

    /// At launch: what's known, an update that was running when the island restarted, and the
    /// news if that update just finished. With `automatic`, a check when the last is 6 h old.
    func start(automatic: Bool) {
        guard !fixed else { return }
        readCheck()
        if let state = readState(), state.state == "running", Date().timeIntervalSince(state.at) < 900 {
            phase = .updating(state.message ?? "Updating tabby…")
            startPolling()
        } else {
            announceFinished()
        }
        setAutomatic(automatic)
    }

    func setAutomatic(_ on: Bool) {
        guard !fixed else { return }
        checkTimer?.invalidate()
        checkTimer = nil
        guard on else { return }
        let timer = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfStale() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfStale() }
    }

    private func checkIfStale() {
        readCheck()
        guard phase == .idle else { return }
        if let at = info.checkedAt, Date().timeIntervalSince(at) < Self.checkEvery { return }
        check(manual: false)
    }

    // MARK: Checking

    /// Asks the CLI (which asks GitHub). `manual`: say the result either way.
    func check(manual: Bool) {
        guard !fixed, !phase.busy else { return }
        phase = .checking
        let wasAvailable = info.available ? info.latest : nil
        Actions.runCLI(["update", "--check", "--json"]) { [weak self] _, output in
            guard let self else { return }
            self.phase = .idle
            if let line = output.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
               let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                self.apply(json)
            } else {
                self.readCheck()
            }
            if self.info.available, let latest = self.info.latest, manual || latest != wasAvailable {
                self.announce?("tabby \(latest) is out", "arrow.down.circle.fill")
            } else if manual {
                if let error = self.info.error, self.info.latest == nil {
                    self.announce?("Couldn't check for updates: \(error)", "exclamationmark.triangle.fill")
                } else {
                    self.announce?("tabby \(self.info.current ?? "") is up to date", "checkmark.circle.fill")
                }
            }
        }
    }

    private func readCheck() {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("update-check.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var next = info
        next.latest = json["latest"] as? String ?? next.latest
        next.error = json["error"] as? String
        if let ms = json["checkedAt"] as? Double { next.checkedAt = Date(timeIntervalSince1970: ms / 1000) }
        next.current = Self.installedVersion() ?? next.current
        next.available = Self.newer(next.latest, than: next.current)
        if next != info { info = next }
    }

    private func apply(_ json: [String: Any]) {
        var next = info
        next.current = json["current"] as? String ?? next.current
        next.latest = json["latest"] as? String ?? next.latest
        next.available = json["available"] as? Bool ?? Self.newer(next.latest, than: next.current)
        next.error = json["error"] as? String
        if let ms = json["checkedAt"] as? Double { next.checkedAt = Date(timeIntervalSince1970: ms / 1000) }
        if next != info { info = next }
    }

    // MARK: Updating

    /// Starts `tabby update` detached (its output goes to update.log), then follows update-state.json.
    func update() {
        guard !fixed, !phase.busy, let cli = Actions.store?.snapshot.cli, !cli.cli.isEmpty else { return }
        let log = dir.appendingPathComponent("update.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli.node)
        process.arguments = [cli.cli, "update", "--quiet"]
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = environment["PATH"].map { "\($0):\(extraPath)" } ?? extraPath
        environment["TABBY_SOURCE"] = "island"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
        } catch {
            phase = .failed("Couldn't start the update: \(error.localizedDescription)")
            return
        }
        phase = .updating("Updating tabby…")
        startPolling()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let started = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(started: started) }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll(started: Date) {
        guard let state = readState() else { return }
        switch state.state {
        case "running":
            if Date().timeIntervalSince(started) > 900 { finish(.failed("The update is taking too long. See ~/.claude/tabby/update.log")) }
            else if let message = state.message, phase != .updating(message) { phase = .updating(message) }
        case "failed":
            finish(.failed(state.message ?? "The update failed. See ~/.claude/tabby/update.log"))
        default:
            finish(.idle)
            readCheck()
            info.available = false
            UserDefaults.standard.set(state.at.timeIntervalSince1970, forKey: Self.announcedKey)
            announce?(state.message ?? "tabby is up to date", "checkmark.circle.fill")
        }
    }

    private func finish(_ next: Phase) {
        pollTimer?.invalidate()
        pollTimer = nil
        phase = next
        if case .failed(let message) = next { announce?(message, "exclamationmark.triangle.fill") }
    }

    /// The island restarted on a new version: say so once.
    private func announceFinished() {
        guard let state = readState(), state.state == "done", Date().timeIntervalSince(state.at) < 900,
              UserDefaults.standard.double(forKey: Self.announcedKey) != state.at.timeIntervalSince1970 else { return }
        UserDefaults.standard.set(state.at.timeIntervalSince1970, forKey: Self.announcedKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.announce?(state.message ?? "tabby is updated", "checkmark.circle.fill")
        }
    }

    private struct State {
        var state: String
        var message: String?
        var at: Date
    }

    private func readState() -> State? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("update-state.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["state"] as? String else { return nil }
        let at = (json["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        return State(state: state, message: json["message"] as? String, at: at)
    }

    // MARK: Helpers

    /// The tabby the CLI runs (the newest installed plugin), from its island.json root.
    private static func installedVersion() -> String? {
        let tabby = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/tabby")
        guard let data = try? Data(contentsOf: tabby.appendingPathComponent("island.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? String,
              let pkg = try? Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("package.json")),
              let manifest = try? JSONSerialization.jsonObject(with: pkg) as? [String: Any] else { return nil }
        return manifest["version"] as? String
    }

    nonisolated static func newer(_ a: String?, than b: String?) -> Bool {
        guard let a, let b else { return false }
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<3 {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// The island header's pill while a newer tabby is out, or one is being installed.
struct UpdatePill: View {
    let badge: UpdateBadge
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if case .updating = badge {
                    ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 11.5, weight: .semibold))
                }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Color(nsColor: Brand.marmalade))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(Color(nsColor: Brand.marmalade).opacity(hover ? 0.26 : 0.17)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(badge == .updating)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var title: String {
        switch badge {
        case .available: return "Update"
        case .updating: return "Updating"
        }
    }

    private var help: String {
        switch badge {
        case .available(let version): return "tabby \(version) is out: click to update (the island restarts)"
        case .updating: return "Updating tabby…"
        }
    }
}

enum UpdateBadge: Equatable {
    case available(String)
    case updating
}
