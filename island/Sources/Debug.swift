import AppKit

/// `TABBY_ISLAND_DEBUG=1` logs what the island does and listens for
/// `dev.tabby.island.debug` distributed notifications (object: a command), so behavior can
/// be driven and checked without Screen Recording. Inert otherwise.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["TABBY_ISLAND_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("tabby island · %@", message())
    }
}

extension IslandController {
    func installDebugChannel() {
        guard Debug.enabled else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.tabby.island.debug"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.debugCommand(command) }
        }
        Debug.log("debug channel ready")
    }

    private func debugCommand(_ command: String) {
        Debug.log("command \(command)")
        let parts = command.split(separator: ":").map(String.init)
        let list = store.listSessions
        switch parts.first ?? "" {
        case "state": Debug.log(debugState())
        case "keyboard": toggleKeyboard()
        case "next": jumpToNextNeedingYou()
        case "tile": tile(parts.count > 1 ? Int(parts[1]) : nil)
        case "mode": cycleMode()
        case "jump": focusSession(at: (Int(parts.last ?? "") ?? 1) - 1)
        case "rename": list.first.map { startRename($0) }
        case "announce":
            switch parts.last {
            case "done": list.first.map { enqueue(.done($0)) }
            case "waiting": list.first.map { enqueue(.waiting($0)) }
            default: enqueue(.info("Allow Accessibility to split tabs", symbol: "hand.raised.fill", topic: "tile",
                                   opensAccessibility: true), force: true)
            }
        case "watermark":
            if parts.count > 1 { Debug.log(watermark.debugState()) } else { toggleWatermark() }
        case "settings":
            openSettings(parts.count > 1 ? SettingsTab(rawValue: parts[1]) : nil)
        case "record":
            if parts.count > 1, let action = ShortcutAction(rawValue: parts[1]) { beginRecording(action) }
        case "key":
            // key:<virtual key code>[:<characters>] — posted to the island's own event queue.
            guard parts.count > 1, let code = UInt16(parts[1]) else { return }
            postKey(code: code, characters: parts.count > 2 ? parts[2] : "")
        default: break
        }
    }
}
