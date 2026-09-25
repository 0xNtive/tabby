import AppKit
import QuartzCore
import SwiftUI

// Everything that loops lives in Core Animation: the render server runs it, so a pulsing
// dot, a spinner or a wiggling bell costs the app no CPU between status changes.

private let noImplicitActions: [String: CAAction] = [
    "position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(),
    "opacity": NSNull(), "transform": NSNull(), "contents": NSNull(), "path": NSNull(),
    "strokeColor": NSNull(), "fillColor": NSNull(), "lineWidth": NSNull(), "anchorPoint": NSNull(),
]

// MARK: - Status dot

struct PulseDot: NSViewRepresentable {
    var hex: String?
    var status: SessionStatus
    var dotSize: CGFloat
    var reduceMotion: Bool
    /// Pop when the status changes, sparkle when a turn finishes (the collapsed dots).
    var celebrates = false

    func makeNSView(context: Context) -> PulseDotView { PulseDotView(frame: .zero) }

    func updateNSView(_ view: PulseDotView, context: Context) {
        view.apply(.init(hex: hex, status: status, dotSize: dotSize, reduceMotion: reduceMotion, celebrates: celebrates))
    }
}

final class PulseDotView: NSView {
    struct Config: Equatable {
        var hex: String?
        var status: SessionStatus
        var dotSize: CGFloat
        var reduceMotion: Bool
        var celebrates: Bool
    }

    /// Halo, dot and ring move together when the dot pops.
    private let stack = CALayer()
    private let halo = CALayer()
    private let dot = CALayer()
    private let ring = CALayer()
    private var config: Config?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        stack.actions = noImplicitActions
        for sublayer in [halo, dot, ring] {
            sublayer.actions = noImplicitActions
            stack.addSublayer(sublayer)
        }
        layer?.addSublayer(stack)
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
        let previous = config
        config = next
        // Expanding/collapsing only flips `celebrates`: keep the running animations.
        if var same = previous {
            same.celebrates = next.celebrates
            if same == next { return }
        }
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

        if let previous, previous.status != next.status, next.celebrates, !next.reduceMotion, window != nil {
            pop()
            if previous.status == .busy, next.status.isYourTurn { sparkle(color) }
        }
    }

    private func layoutLayers() {
        guard let config else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stack.bounds = bounds
        stack.position = CGPoint(x: bounds.midX, y: bounds.midY)
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

    /// A springy 1 → 1.6 → 1.
    private func pop() {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.6, 0.9, 1.05, 1.0]
        pop.keyTimes = [0, 0.28, 0.6, 0.82, 1]
        pop.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        pop.duration = 0.55
        stack.add(pop, forKey: "pop")
    }

    /// A ring flash plus a few sparks in the session's color, ~0.7 s.
    private func sparkle(_ color: CGColor) {
        guard let host = layer, let config else { return }
        let burst = CALayer()
        burst.frame = bounds
        burst.actions = noImplicitActions
        host.addSublayer(burst)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = config.dotSize / 2

        CATransaction.begin()
        CATransaction.setCompletionBlock { burst.removeFromSuperlayer() }

        let flash = CAShapeLayer()
        flash.actions = noImplicitActions
        flash.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        flash.position = center
        flash.path = CGPath(ellipseIn: flash.bounds, transform: nil)
        flash.fillColor = nil
        flash.strokeColor = color
        flash.lineWidth = 1.4
        flash.opacity = 0
        burst.addSublayer(flash)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1.0
        grow.toValue = 2.9
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0.0
        let ringAnimation = CAAnimationGroup()
        ringAnimation.animations = [grow, fade]
        ringAnimation.duration = 0.7
        ringAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(ringAnimation, forKey: "flash")

        let sparks = 7
        let twist = Double.random(in: 0..<(2 * .pi / Double(sparks)))
        for index in 0..<sparks {
            let spark = CALayer()
            spark.actions = noImplicitActions
            let side: CGFloat = index.isMultiple(of: 2) ? 2.4 : 1.8
            spark.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            spark.cornerRadius = side / 2
            spark.backgroundColor = index.isMultiple(of: 3) ? NSColor.white.withAlphaComponent(0.9).cgColor : color
            spark.position = center
            spark.opacity = 0
            burst.addSublayer(spark)
            let angle = twist + Double(index) / Double(sparks) * 2 * .pi
            let distance = radius + 7 + CGFloat.random(in: 0...3)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: center)
            move.toValue = NSValue(point: CGPoint(x: center.x + CGFloat(cos(angle)) * distance,
                                                  y: center.y + CGFloat(sin(angle)) * distance))
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
            let shine = CAKeyframeAnimation(keyPath: "opacity")
            shine.values = [0, 1, 1, 0]
            shine.keyTimes = [0, 0.12, 0.55, 1]
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.0
            shrink.toValue = 0.35
            let group = CAAnimationGroup()
            group.animations = [move, shine, shrink]
            group.duration = 0.7
            spark.add(group, forKey: "spark")
        }
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
        arc.actions = noImplicitActions
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

// MARK: - Bell (rings when the waiting count rises, then a gentle wiggle every ~6 s)

struct Bell: NSViewRepresentable {
    var count: Int
    var reduceMotion: Bool

    func makeNSView(context: Context) -> BellView { BellView(frame: .zero) }

    func updateNSView(_ view: BellView, context: Context) {
        view.configure(count: count, reduceMotion: reduceMotion)
    }
}

final class BellView: NSView {
    private let bell = CALayer()
    private var count = 0
    private var reduceMotion = false
    private var imageScale: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        bell.actions = noImplicitActions
        bell.contentsGravity = .resizeAspect
        layer?.addSublayer(bell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutBell()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateImage()
        restartIdle()
        // A bell that appears was just "rung" (the first session started waiting).
        if window != nil, count > 0 { ring() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateImage()
    }

    func configure(count: Int, reduceMotion: Bool) {
        let rose = count > self.count && self.count > 0
        self.count = count
        if reduceMotion != self.reduceMotion {
            self.reduceMotion = reduceMotion
            restartIdle()
        }
        if rose { ring() }
    }

    private func updateImage() {
        let scale = window?.backingScaleFactor ?? 2
        guard scale != imageScale else { return }
        imageScale = scale
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Palette.waitingNS]))
        guard let image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Waiting")?
            .withSymbolConfiguration(configuration) else { return }
        bell.contentsScale = scale
        bell.contents = image.layerContents(forContentsScale: scale)
        bell.bounds = CGRect(origin: .zero, size: image.size)
        layoutBell()
    }

    private func layoutBell() {
        // Swing from the top of the bell (layer coordinates are y-up here).
        bell.anchorPoint = CGPoint(x: 0.5, y: 0.9)
        bell.position = CGPoint(x: bounds.midX, y: bounds.midY + bell.bounds.height * 0.4)
    }

    private func wiggle(amplitude: Double, duration: Double) -> CAKeyframeAnimation {
        let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wiggle.values = [0, amplitude, -amplitude * 0.85, amplitude * 0.6, -amplitude * 0.35, amplitude * 0.12, 0]
        wiggle.keyTimes = [0, 0.14, 0.32, 0.5, 0.68, 0.84, 1]
        wiggle.duration = duration
        wiggle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return wiggle
    }

    private func ring() {
        guard window != nil, !reduceMotion else { return }
        bell.add(wiggle(amplitude: 0.5, duration: 0.8), forKey: "ring")
    }

    private func restartIdle() {
        bell.removeAnimation(forKey: "idle")
        guard window != nil, !reduceMotion else { return }
        let gentle = wiggle(amplitude: 0.22, duration: 0.65)
        gentle.beginTime = 5.35
        let loop = CAAnimationGroup()
        loop.animations = [gentle]
        loop.duration = 6
        loop.repeatCount = .infinity
        bell.add(loop, forKey: "idle")
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

    /// Four accents spread across the palette (red, yellow, teal, purple for a full theme).
    static func sample(_ accents: [Accent]) -> [Accent] {
        guard accents.count > 4 else { return accents }
        return (0..<4).map { accents[$0 * accents.count / 4] }
    }

    /// A chip in the theme's background with four of its accent dots.
    static func theme(_ theme: ThemeInfo) -> NSImage {
        let background = NSColor(hexString: theme.bg) ?? .black
        let dots = sample(theme.accents).map { NSColor(hexString: $0.dot) ?? .gray }
        let image = NSImage(size: NSSize(width: 46, height: 14), flipped: false) { rect in
            let chip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            background.setFill()
            chip.fill()
            NSColor(white: 0.5, alpha: 0.35).setStroke()
            chip.lineWidth = 0.5
            chip.stroke()
            let diameter: CGFloat = 6, gap: CGFloat = 3.5
            let total = CGFloat(dots.count) * diameter + CGFloat(max(0, dots.count - 1)) * gap
            var x = rect.midX - total / 2
            for dot in dots {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY - diameter / 2, width: diameter, height: diameter)).fill()
                x += diameter + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
