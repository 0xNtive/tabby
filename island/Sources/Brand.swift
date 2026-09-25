import AppKit
import QuartzCore
import SwiftUI

// MARK: - The tabby cat (brand/logo.svg, viewBox 0 0 64 64, y down)

enum CatGeometry {
    /// Tight bounds of the head in viewBox units.
    static let bounds = CGRect(x: 7, y: 6.5, width: 50, height: 51)

    static let head: CGPath = {
        // M10 24 13.5 8.6Q14 6.5 15.8 7.7L26.5 15.4Q32 13.7 37.5 15.4L48.2 7.7Q50 6.5 50.5 8.6
        // L54 24Q57 30 57 37.5 57 57.5 32 57.5 7 57.5 7 37.5 7 30 10 24Z
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 10, y: 24))
        path.addLine(to: CGPoint(x: 13.5, y: 8.6))
        path.addQuadCurve(to: CGPoint(x: 15.8, y: 7.7), control: CGPoint(x: 14, y: 6.5))
        path.addLine(to: CGPoint(x: 26.5, y: 15.4))
        path.addQuadCurve(to: CGPoint(x: 37.5, y: 15.4), control: CGPoint(x: 32, y: 13.7))
        path.addLine(to: CGPoint(x: 48.2, y: 7.7))
        path.addQuadCurve(to: CGPoint(x: 50.5, y: 8.6), control: CGPoint(x: 50, y: 6.5))
        path.addLine(to: CGPoint(x: 54, y: 24))
        path.addQuadCurve(to: CGPoint(x: 57, y: 37.5), control: CGPoint(x: 57, y: 30))
        path.addQuadCurve(to: CGPoint(x: 32, y: 57.5), control: CGPoint(x: 57, y: 57.5))
        path.addQuadCurve(to: CGPoint(x: 7, y: 37.5), control: CGPoint(x: 7, y: 57.5))
        path.addQuadCurve(to: CGPoint(x: 10, y: 24), control: CGPoint(x: 7, y: 30))
        path.closeSubpath()
        return path
    }()

    /// The three forehead stripes (the "tabs"): blue, green, orange.
    static let stripes: [CGPath] = [
        stripe(CGRect(x: 22.4, y: 19.2, width: 4.2, height: 10), degrees: -14),
        stripe(CGRect(x: 29.9, y: 17.6, width: 4.2, height: 11.4), degrees: 0),
        stripe(CGRect(x: 37.4, y: 19.2, width: 4.2, height: 10), degrees: 14),
    ]

    static let eyes: [CGRect] = [
        CGRect(x: 23.2 - 3.3, y: 38.4 - 3.7, width: 6.6, height: 7.4),
        CGRect(x: 40.8 - 3.3, y: 38.4 - 3.7, width: 6.6, height: 7.4),
    ]

    static let nose: CGPath = {
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 29.6, y: 43.4), CGPoint(x: 34.4, y: 43.4), CGPoint(x: 32, y: 46.2)])
        path.closeSubpath()
        return path
    }()

    static let innerEars: CGPath = {
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 17.2, y: 13.6), CGPoint(x: 18.9, y: 10.4), CGPoint(x: 23.1, y: 13.8)])
        path.closeSubpath()
        path.addLines(between: [CGPoint(x: 46.8, y: 13.6), CGPoint(x: 45.1, y: 10.4), CGPoint(x: 40.9, y: 13.8)])
        path.closeSubpath()
        return path
    }()

    /// M28.2 48.2q1.9 1.9 3.8 0 1.9 1.9 3.8 0 (stroked)
    static let mouth: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 28.2, y: 48.2))
        path.addQuadCurve(to: CGPoint(x: 32, y: 48.2), control: CGPoint(x: 30.1, y: 50.1))
        path.addQuadCurve(to: CGPoint(x: 35.8, y: 48.2), control: CGPoint(x: 33.9, y: 50.1))
        return path
    }()

    /// Head with stripe, eye and nose holes: fill with the even-odd rule (brand/logo-mono.svg).
    static let silhouette: CGPath = {
        let path = CGMutablePath()
        path.addPath(head)
        stripes.forEach { path.addPath($0) }
        eyes.forEach { path.addEllipse(in: $0) }
        path.addPath(nose)
        return path
    }()

    private static func stripe(_ rect: CGRect, degrees: CGFloat) -> CGPath {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        let radius = rect.width / 2 * 0.999
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: &transform)
    }

    /// Maps viewBox units (y down) into a y-up box of `size`, centered, `inset` points from the edges.
    static func transform(fitting size: CGSize, inset: CGFloat = 0) -> (CGAffineTransform, CGFloat) {
        let scale = min((size.width - 2 * inset) / bounds.width, (size.height - 2 * inset) / bounds.height)
        let x = (size.width - bounds.width * scale) / 2 - bounds.minX * scale
        let y = (size.height - bounds.height * scale) / 2 + bounds.maxY * scale
        return (CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: x, ty: y), scale)
    }
}

enum Brand {
    static let ink = NSColor(hexString: "#262b35")!
    static let cream = NSColor(hexString: "#f4ede0")!
    static let blush = NSColor(hexString: "#e394c1")!
    static let earPink = NSColor(hexString: "#e3a5c2")!
    static let stripeColors = ["#77b7f4", "#7fc489", "#e79e6b"].map { NSColor(hexString: $0)! }

    static let github = URL(string: "https://github.com/0xNtive/tabby")!
    static let website = URL(string: "https://claude-tabby.vercel.app")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The menu-bar icon: the cat as a template image, stripes, eyes and nose cut out.
    static func statusIcon(pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            var (transform, _) = CatGeometry.transform(fitting: rect.size, inset: 0.5)
            guard let path = CatGeometry.silhouette.copy(using: &transform) else { return false }
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "tabby"
        return image
    }
}

// MARK: - Full-color cat (Core Animation, so the blink costs no CPU)

struct CatMark: NSViewRepresentable {
    /// Blink every 6–10 s. Only the expanded footer shows the cat, so it only blinks then.
    var blinks: Bool

    func makeNSView(context: Context) -> CatMarkView { CatMarkView(frame: .zero) }

    func updateNSView(_ view: CatMarkView, context: Context) {
        view.setBlinking(blinks)
    }
}

final class CatMarkView: NSView {
    private let body = CAShapeLayer()
    private let innerEars = CAShapeLayer()
    private let stripes = (0..<3).map { _ in CAShapeLayer() }
    private let eyes = (0..<2).map { _ in CAShapeLayer() }
    private let nose = CAShapeLayer()
    private let mouth = CAShapeLayer()
    private var blinking = false
    private var laidOutSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        body.fillColor = Brand.ink.cgColor
        // A faint rim keeps the ink-colored head readable on the black island.
        body.strokeColor = NSColor(white: 1, alpha: 0.16).cgColor
        innerEars.fillColor = Brand.earPink.withAlphaComponent(0.55).cgColor
        for (layer, color) in zip(stripes, Brand.stripeColors) { layer.fillColor = color.cgColor }
        eyes.forEach { $0.fillColor = Brand.cream.cgColor }
        nose.fillColor = Brand.blush.cgColor
        mouth.fillColor = nil
        mouth.strokeColor = Brand.cream.cgColor
        mouth.lineCap = .round
        mouth.lineJoin = .round
        for sublayer in [body, innerEars] + stripes + eyes + [nose, mouth] {
            sublayer.actions = noActions
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private let noActions: [String: CAAction] = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                                 "transform": NSNull(), "lineWidth": NSNull()]

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize, bounds.width > 0 else { return }
        laidOutSize = bounds.size
        var (transform, scale) = CatGeometry.transform(fitting: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.path = CatGeometry.head.copy(using: &transform)
        body.lineWidth = max(0.5, 1.1 * scale)
        innerEars.path = CatGeometry.innerEars.copy(using: &transform)
        for (layer, path) in zip(stripes, CatGeometry.stripes) { layer.path = path.copy(using: &transform) }
        nose.path = CatGeometry.nose.copy(using: &transform)
        mouth.path = CatGeometry.mouth.copy(using: &transform)
        mouth.lineWidth = max(0.6, 1.5 * scale)
        // Eyes get their own bounds so they can blink around their centers.
        for (layer, rect) in zip(eyes, CatGeometry.eyes) {
            let frame = rect.applying(transform)
            layer.bounds = CGRect(origin: .zero, size: frame.size)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
            layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBlink()
    }

    func setBlinking(_ on: Bool) {
        guard on != blinking else { return }
        blinking = on
        updateBlink()
    }

    /// One long keyframe loop with blinks at random 6–10 s gaps (now and then a double
    /// blink): the render server plays it, the app never wakes up for it.
    private func updateBlink() {
        eyes.forEach { $0.removeAnimation(forKey: "blink") }
        guard blinking, window != nil else { return }
        var times: [Double] = []
        var t = Double.random(in: 2.5...4.5)
        for _ in 0..<6 {
            times.append(t)
            t += Double.random(in: 6...10)
        }
        let cycle = times.last! + Double.random(in: 6...10) - times[0]
        var keyTimes: [Double] = [0]
        var values: [Double] = [1]
        func blink(at start: Double) {
            keyTimes += [start, start + 0.045, start + 0.125, start + 0.17]
            values += [1, 0.1, 0.1, 1]
        }
        for (index, start) in times.enumerated() {
            blink(at: start)
            if index % 3 == 1 { blink(at: start + 0.3) }
        }
        let end = times.last! + 1
        let duration = max(end, cycle)
        keyTimes.append(duration)
        values.append(1)
        let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
        animation.values = values
        animation.keyTimes = keyTimes.map { NSNumber(value: $0 / duration) }
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        eyes.forEach { $0.add(animation, forKey: "blink") }
    }
}
