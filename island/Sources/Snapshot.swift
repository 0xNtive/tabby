import AppKit
import SwiftUI

/// `TabbyIsland --snapshot <dir>` renders the island with live data (collapsed, expanded,
/// expanded with the first row hovered) to PNGs over a sample desktop, so the design can be
/// checked without Screen Recording permission.
@MainActor
enum Snapshotter {
    static func run(directory: String) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = SessionStore(automation: false)
        store.refresh()
        let deadline = Date().addingTimeInterval(5)
        while store.snapshot.cli.cli.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let (geometry, rect) = IslandGeometry.current()
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let actions = IslandActions(islandFrame: { _ in }, rowFrames: { _ in }, viewport: { _ in }, expand: {},
                                    tapRow: { _ in }, sessionMenu: { _ in }, themeAllMenu: {})

        for (name, expanded, hoverFirst) in [("collapsed", false, false), ("expanded", true, false), ("hover", true, true)] {
            let ui = IslandUIState()
            ui.geometry = geometry
            ui.expanded = expanded
            ui.hoveredRow = hoverFirst ? store.listSessions.first?.id : nil
            let host = NSHostingView(rootView: IslandRootView(store: store, ui: ui, actions: actions))
            host.frame = NSRect(origin: .zero, size: rect.size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = folder.appendingPathComponent("island-\(name).png")
            if let data = composite(rep, size: rect.size, barHeight: geometry.barHeight).representation(using: .png, properties: [:]) {
                try? data.write(to: file)
                print(file.path)
            }
            window.close()
        }
    }

    /// Draws the rendered panel over a gradient "wallpaper" with a menu-bar strip.
    private static func composite(_ island: NSBitmapImageRep, size: CGSize, barHeight: CGFloat) -> NSBitmapImageRep {
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: island.pixelsWide, pixelsHigh: island.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return island }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let bounds = NSRect(origin: .zero, size: size)
        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.25, blue: 0.40, alpha: 1),
                            NSColor(srgbRed: 0.40, green: 0.29, blue: 0.45, alpha: 1)])?.draw(in: bounds, angle: -60)
        NSColor(white: 1, alpha: 0.16).setFill()
        NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight).fill()
        island.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}
