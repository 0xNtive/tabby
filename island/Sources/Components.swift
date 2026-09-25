import AppKit
import QuartzCore
import SwiftUI

// MARK: - Status dot (Core Animation, so idle pulses cost no CPU)

struct PulseDot: NSViewRepresentable {
    var hex: String?
    var status: SessionStatus
    var dotSize: CGFloat
    var reduceMotion: Bool

    func makeNSView(context: Context) -> PulseDotView { PulseDotView(frame: .zero) }

    func updateNSView(_ view: PulseDotView, context: Context) {
        view.apply(.init(hex: hex, status: status, dotSize: dotSize, reduceMotion: reduceMotion))
    }
}

final class PulseDotView: NSView {
    struct Config: Equatable {
        var hex: String?
        var status: SessionStatus
        var dotSize: CGFloat
        var reduceMotion: Bool
    }

    private let halo = CALayer()
    private let dot = CALayer()
    private let ring = CALayer()
    private var config: Config?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for sublayer in [halo, dot, ring] {
            sublayer.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(),
                                "borderColor": NSNull(), "opacity": NSNull(), "transform": NSNull()]
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    func apply(_ next: Config) {
        guard next != config else { return }
        config = next
        let color = (NSColor(hexString: next.hex) ?? NSColor(hexString: Palette.neutralHex) ?? .gray).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.removeAllAnimations()
        ring.removeAllAnimations()
        dot.backgroundColor = color
        dot.opacity = next.status == .ended ? 0.45 : 1
        halo.backgroundColor = color
        halo.opacity = 0
        halo.transform = CATransform3DIdentity
        ring.backgroundColor = nil
        ring.borderWidth = 1.6
        ring.opacity = 0

        switch next.status {
        case .busy:
            if next.reduceMotion {
                halo.opacity = 0.28
                halo.transform = CATransform3DMakeScale(1.6, 1.6, 1)
            } else {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 1.0
                grow.toValue = 2.1
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.5
                fade.toValue = 0.0
                let ping = CAAnimationGroup()
                ping.animations = [grow, fade]
                ping.duration = 1.7
                ping.repeatCount = .infinity
                ping.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // De-sync neighbouring dots so the island doesn't blink in unison.
                ping.beginTime = CACurrentMediaTime() + Double.random(in: 0...0.9)
                halo.add(ping, forKey: "ping")
            }
        case .waiting:
            ring.borderColor = Palette.waitingNS.cgColor
            ring.opacity = 1
            if !next.reduceMotion {
                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 1.0
                blink.toValue = 0.3
                blink.duration = 0.9
                blink.autoreverses = true
                blink.repeatCount = .infinity
                blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ring.add(blink, forKey: "blink")
            }
        case .error:
            ring.borderColor = Palette.dangerNS.cgColor
            ring.opacity = 1
        default:
            break
        }
        CATransaction.commit()
        layoutLayers()
    }

    private func layoutLayers() {
        guard let config else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let size = config.dotSize
        for sublayer in [halo, dot] {
            sublayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            sublayer.position = center
            sublayer.cornerRadius = size / 2
        }
        let ringSize = size + 5
        ring.bounds = CGRect(x: 0, y: 0, width: ringSize, height: ringSize)
        ring.position = center
        ring.cornerRadius = ringSize / 2
        CATransaction.commit()
    }
}

// MARK: - Spinner (Core Animation; SwiftUI's ProgressView re-renders every frame and kept
// the collapsed island at ~4% CPU whenever a session was busy)

struct Spinner: NSViewRepresentable {
    var color: NSColor
    var lineWidth: CGFloat = 1.5
    var reduceMotion: Bool

    func makeNSView(context: Context) -> SpinnerView { SpinnerView(frame: .zero) }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.configure(color: color, lineWidth: lineWidth, reduceMotion: reduceMotion)
    }
}

final class SpinnerView: NSView {
    private let arc = CAShapeLayer()
    private var reduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeEnd = 0.7
        arc.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(),
                       "strokeColor": NSNull(), "lineWidth": NSNull()]
        layer?.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutArc()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    func configure(color: NSColor, lineWidth: CGFloat, reduceMotion: Bool) {
        arc.strokeColor = color.cgColor
        arc.lineWidth = lineWidth
        if reduceMotion != self.reduceMotion {
            self.reduceMotion = reduceMotion
            updateAnimation()
        }
        layoutArc()
    }

    private func layoutArc() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let inset = arc.lineWidth / 2 + 0.5
        arc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        arc.path = CGPath(ellipseIn: arc.bounds.insetBy(dx: inset, dy: inset), transform: nil)
    }

    private func updateAnimation() {
        arc.removeAnimation(forKey: "spin")
        guard window != nil, !reduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.1
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        arc.add(spin, forKey: "spin")
    }
}

// MARK: - Right-click / control-click catcher

/// Transparent overlay that only claims secondary clicks, so left clicks and hover still
/// reach the SwiftUI content underneath.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (NSEvent) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView(frame: .zero)
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((NSEvent) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown, .leftMouseUp:
                return event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
            default:
                return nil
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onRightClick?(event) }
        }
    }
}

// MARK: - Menu swatches

enum Swatch {
    static func dot(_ hex: String, diameter: CGFloat = 12) -> NSImage {
        let color = NSColor(hexString: hex) ?? .gray
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            color.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.22).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A tiny chip in the theme's background with four of its accents.
    static func theme(_ theme: ThemeInfo) -> NSImage {
        let background = NSColor(hexString: theme.bg) ?? .black
        let accents = theme.accents.prefix(4).map { NSColor(hexString: $0.hex) ?? .gray }
        let image = NSImage(size: NSSize(width: 46, height: 14), flipped: false) { rect in
            let chip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            background.setFill()
            chip.fill()
            NSColor(white: 0.5, alpha: 0.35).setStroke()
            chip.lineWidth = 0.5
            chip.stroke()
            let diameter: CGFloat = 6, gap: CGFloat = 3.5
            let total = CGFloat(accents.count) * diameter + CGFloat(max(0, accents.count - 1)) * gap
            var x = rect.midX - total / 2
            for accent in accents {
                accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY - diameter / 2, width: diameter, height: diameter)).fill()
                x += diameter + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
