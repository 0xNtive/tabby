import AppKit
import SwiftUI

// `--snapshot` renders for Settings › Windows (three made-up screens, one portrait), the tile
// picker and quick launch, so their design can be checked without Screen Recording.
extension Snapshotter {
    static func renderWindowsFeatures(store: SessionStore, folder: URL) {
        // Settings › Windows with a laptop, the main screen and a vertical monitor: sessions
        // only on the vertical one.
        ScreenInfo.override = [
            ScreenInfo(key: "LAPTOP", name: "Built-in Retina Display", frame: CGRect(x: -1512, y: 0, width: 1512, height: 982), hasNotch: true),
            ScreenInfo(key: "MAIN", name: "HP E273q", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isPrimary: true),
            ScreenInfo(key: "DELL", name: "DELL U2720Q", frame: CGRect(x: 2560, y: -560, width: 1440, height: 2560)),
        ]
        let island = IslandController(store: store, inert: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var config = island.settingsState.config
            config.tileScreens = .chosen(["DELL"])
            config.tileScope = .active
            config.launchSkipPermissions = appearance == .darkAqua
            island.settingsState.config = config
            island.settingsState.tab = .windows
            let view = SettingsView(island: island, store: store, state: island.settingsState)
            render(view, size: CGSize(width: 600, height: 640), appearance: appearance,
                   to: folder.appendingPathComponent("windows-settings-3screens-\(appearance == .darkAqua ? "dark" : "light").png"))
        }
        ScreenInfo.override = nil

        // The tile picker: demo sessions, one of them in VS Code (can't be tiled).
        var sessions = store.snapshot.sessions
        for index in sessions.indices {
            sessions[index].tty = "/dev/ttys00\(index)"
            sessions[index].term = index == 3 ? "vscode" : "apple-terminal"
        }
        let picker = TilePickerModel()
        picker.sessions = sessions
        picker.selectActive()
        picker.screensText = "DELL U2720Q"
        render(TilePickerView(model: picker, tile: {}, cancel: {}), size: TilePickerController.size(for: sessions.count),
               to: folder.appendingPathComponent("tile-picker.png"))

        // Quick launch, as it opens and with "Skip permissions" ticked after typing.
        let now = Date().timeIntervalSince1970 * 1000
        let launch = QuickLaunchModel()
        launch.folders = [
            RecentFolder(path: "/Users/me/Dev/wildcat", name: "wildcat", display: "~/Dev/wildcat", sessions: 31, live: 2, lastUsed: now - 60_000),
            RecentFolder(path: "/Users/me/Dev/wildfire", name: "wildfire", display: "~/Dev/wildfire", sessions: 14, live: 1, lastUsed: now - 300_000),
            RecentFolder(path: "/Users/me/Dev/atlas", name: "atlas", display: "~/Dev/atlas", sessions: 13, lastUsed: now - 20 * 3_600_000),
            RecentFolder(path: "/Users/me/Dev/tabby", name: "tabby", display: "~/Dev/tabby", sessions: 9, lastUsed: now - 26 * 3_600_000),
            RecentFolder(path: "/Users/me/Dev/storefront", name: "storefront", display: "~/Dev/storefront", sessions: 9, lastUsed: now - 3 * 86_400_000),
            RecentFolder(path: "/Users/me/Dev/nightowl", name: "nightowl", display: "~/Dev/nightowl", sessions: 7, lastUsed: now - 6 * 86_400_000),
            RecentFolder(path: "/Users/me/Dev/ledger", name: "ledger", display: "~/Dev/ledger", sessions: 5, lastUsed: now - 12 * 86_400_000),
            RecentFolder(path: "/Users/me/Dev/trailmap", name: "trailmap", display: "~/Dev/trailmap", sessions: 5, lastUsed: now - 20 * 86_400_000),
        ]
        render(QuickLaunchView(model: launch), size: QuickLaunchController.size, to: folder.appendingPathComponent("quick-launch.png"))
        launch.query = "wild"
        launch.selection = 1
        launch.name = "Billing bug"
        launch.skipPermissions = true
        render(QuickLaunchView(model: launch), size: QuickLaunchController.size, to: folder.appendingPathComponent("quick-launch-skip.png"))
    }

    /// A view on a plain window background (for the floating panels: a desktop-like gray).
    private static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name = .darkAqua, to file: URL) {
        let backdrop = ZStack {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
            view
        }
        let host = NSHostingView(rootView: backdrop.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.moveToRetinaScreen()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.snapshotRep() else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: file)
            print(file.path)
        }
        window.close()
    }
}
