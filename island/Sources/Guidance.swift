import AppKit
import SwiftUI

// What the island's controls do, said in the island itself, and how far along a tile is
// (TileProgress, in Models.swift). The island's app is almost never active, so macOS tooltips
// (.help) rarely show over it: hovering a toolbar control shows a hint under the toolbar instead.

// MARK: - Progress ring

/// A ring that fills as the work gets done and turns slowly while it does, so a long step
/// never looks stuck. Core Animation, like the spinner: no SwiftUI animation loop.
struct ProgressRing: NSViewRepresentable {
    var fraction: Double
    var color: NSColor = .white
    var lineWidth: CGFloat = 1.75
    var reduceMotion: Bool

    func makeNSView(context: Context) -> ProgressRingView { ProgressRingView(frame: .zero) }

    func updateNSView(_ view: ProgressRingView, context: Context) {
        view.configure(fraction: fraction, color: color, lineWidth: lineWidth, reduceMotion: reduceMotion)
    }
}

final class ProgressRingView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var reduceMotion = false
    private var fraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutRing()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpin()
    }

    func configure(fraction: Double, color: NSColor, lineWidth: CGFloat, reduceMotion: Bool) {
        track.strokeColor = color.withAlphaComponent(0.22).cgColor
        arc.strokeColor = color.cgColor
        track.lineWidth = lineWidth
        arc.lineWidth = lineWidth
        // A sliver from the start, so the ring reads as "started".
        let end = CGFloat(max(0.08, min(fraction, 1)))
        if end != arc.strokeEnd {
            if reduceMotion || window == nil {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                arc.strokeEnd = end
                CATransaction.commit()
            } else {
                let grow = CABasicAnimation(keyPath: "strokeEnd")
                grow.fromValue = arc.presentation()?.strokeEnd ?? arc.strokeEnd
                grow.toValue = end
                grow.duration = 0.45
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                arc.strokeEnd = end
                arc.add(grow, forKey: "grow")
            }
        }
        if reduceMotion != self.reduceMotion {
            self.reduceMotion = reduceMotion
            updateSpin()
        }
        layoutRing()
    }

    private func layoutRing() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let inset = arc.lineWidth / 2 + 0.5
        for shape in [track, arc] {
            shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
            // Starts at twelve o'clock and fills clockwise (the layer isn't flipped).
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: side / 2 - inset,
                        startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            shape.path = path
        }
    }

    private func updateSpin() {
        arc.removeAnimation(forKey: "spin")
        guard window != nil, !reduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 2.4
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

// MARK: - Toolbar hints

/// The controls in the expanded island's toolbar, for the hint under it.
enum ToolbarControl: Hashable {
    case mode(IslandMode)
    case tile
    case history
    case processes
    case settings
    case update
}

struct ControlFramesKey: PreferenceKey {
    static let defaultValue: [ToolbarControl: CGRect] = [:]
    static func reduce(value: inout [ToolbarControl: CGRect], nextValue: () -> [ToolbarControl: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports where a toolbar control is, so hovering it shows its hint.
    func toolbarControl(_ control: ToolbarControl) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ControlFramesKey.self, value: [control: proxy.frame(in: .named(IslandSpace.name))])
        })
    }
}

struct ToolbarHintContent: Equatable {
    var symbol: String
    var title: String
    var detail: String
    /// "⌃⌥G", when that control has a shortcut.
    var shortcut: String?
    var progress: Double?
}

extension ToolbarHintContent {
    static func make(_ control: ToolbarControl, config: IslandConfig, update: UpdateBadge?,
                     tiling: TileProgress?, stale: ProcessScan.Totals? = nil) -> ToolbarHintContent {
        let key = { (action: ShortcutAction) -> String? in
            guard config.hotkeys, let combo = config.shortcuts[action] else { return nil }
            return action.display(combo)
        }
        switch control {
        case .mode(let mode):
            return ToolbarHintContent(symbol: mode.symbol, title: "\(mode.title) view", detail: mode.hint, shortcut: key(.mode))
        case .tile:
            if let tiling {
                return ToolbarHintContent(symbol: "rectangle.split.2x2", title: "Tiling your windows…", detail: tiling.detail,
                                          shortcut: nil, progress: tiling.fraction)
            }
            let which = config.tileScope == .active ? "the sessions that are working or need you" : "every session"
            let colors = config.tileRecolor ? ", each in its own color" : ""
            return ToolbarHintContent(symbol: "rectangle.split.2x2", title: "Tile windows",
                                      detail: "Puts the windows of \(which) side by side\(colors). Click to choose which.",
                                      shortcut: key(.tile))
        case .history:
            return ToolbarHintContent(symbol: IslandPage.history.symbol, title: "History",
                                      detail: "The sessions you ran before. Click one to go back to it: a new window picks up right where it ended.",
                                      shortcut: nil)
        case .processes:
            if let stale, stale.count > 0 {
                return ToolbarHintContent(symbol: IslandPage.processes.symbol,
                                          title: "\(stale.count) stale process\(stale.count == 1 ? "" : "es") · \(Fmt.memory(stale.memMB))",
                                          detail: "Dev servers and leftovers from closed or long-idle sessions. Click to see them and stop them in one go.",
                                          shortcut: nil)
            }
            return ToolbarHintContent(symbol: IslandPage.processes.symbol, title: "Processes",
                                      detail: "Dev servers and leftovers your terminals started, and the CPU and memory they use. Stop them in one click.",
                                      shortcut: nil)
        case .settings:
            return ToolbarHintContent(symbol: "gearshape.fill", title: "Settings",
                                      detail: "Shortcuts, screens, focus mode, the watermark and more.", shortcut: key(.settings))
        case .update:
            if case .available(let version) = update {
                return ToolbarHintContent(symbol: "arrow.down.circle.fill", title: "Update to tabby \(version)",
                                          detail: "Installs it in the background; the island restarts when it's done.", shortcut: nil)
            }
            return ToolbarHintContent(symbol: "arrow.down.circle.fill", title: "Updating tabby…",
                                      detail: "The island restarts when it's done.", shortcut: nil)
        }
    }
}

/// The hint card under the toolbar: what the hovered control does, and its shortcut.
struct ToolbarHint: View {
    let content: ToolbarHintContent
    let reduceMotion: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(Color.white.opacity(0.1))
                if let progress = content.progress {
                    ProgressRing(fraction: progress, reduceMotion: reduceMotion)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: content.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(content.detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .lineLimit(2)
            Spacer(minLength: 0)
            if let shortcut = content.shortcut {
                Text(shortcut)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .frame(minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.13)))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.115))
                .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
