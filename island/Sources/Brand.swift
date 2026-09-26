import AppKit
import QuartzCore
import SwiftUI

// MARK: - The tabby cat (brand/logo.svg, a 2048-unit viewBox, y down; stored here in 64 units)

enum CatGeometry {
    /// Tight bounds of the cat (head and ears) in 64-unit viewBox coordinates.
    static let bounds = CGRect(x: 13.169, y: 13.151, width: 37.672, height: 37.76)

    /// The head, its three forehead stripes (the "tabs") cut into the outline.
    static let head = svgPath("M 1075.06 596.563 C 1103.58 597.124 1133.09 596.87 1161.67 596.968 C 1161.1 612.758 1161.75 632.101 1161.79 648.136 L 1161.94 748.863 L 1161.73 805.718 C 1161.61 827.183 1158.69 852.031 1173.32 869.408 C 1181.46 879.109 1193.21 885.056 1205.84 885.864 C 1219.21 886.661 1232.29 881.829 1241.93 872.539 C 1255.14 859.889 1257.82 846.321 1257.92 829.044 C 1258.37 751.907 1256.26 674.042 1257.76 596.96 C 1354.48 599.746 1446.38 639.848 1514.2 708.868 C 1573.4 767.806 1611.44 844.68 1622.38 927.5 C 1626.68 962.715 1625.89 995.426 1625.92 1030.88 L 1625.93 1180.58 C 1625.93 1214.91 1626.89 1254.88 1623.52 1288.57 C 1615.28 1363.82 1585.1 1434.98 1536.72 1493.2 C 1473.31 1569.05 1382.1 1616.28 1283.56 1624.29 C 1253.12 1626.82 1220.72 1625.97 1190.05 1625.91 L 1053.71 1625.75 L 882.821 1625.93 C 826.153 1626.08 771.001 1629.16 715.436 1617 C 660.049 1604.87 601.072 1576.2 557.78 1539.32 C 479.762 1473.95 431.319 1379.95 423.363 1278.48 C 421.402 1253.15 421.976 1228.01 422.016 1202.61 L 422.075 1101.83 L 422.075 1012.15 C 422.083 990.876 421.656 968.871 423.377 947.724 C 429.614 867.321 461.28 790.989 513.789 729.782 C 581.968 650.383 673.676 605.226 777.595 597.419 C 780.389 597.039 787.224 597.048 790.336 596.96 L 790.275 761.055 C 790.226 784.069 790.079 807.084 790.227 830.097 C 790.33 846.124 792.617 858.693 804.068 870.885 C 812.715 880.254 824.861 885.617 837.611 885.695 C 850.369 885.821 863.913 880.714 873 871.691 C 879.944 864.763 884.535 855.827 886.123 846.147 C 888.209 833.935 887.349 785.433 887.369 770.315 L 887.133 596.955 L 974.886 597.066 C 976.173 672.366 975.264 750.06 975.137 825.589 L 975.038 886.208 C 975.019 909.161 971.785 932.601 988.701 950.674 C 997.444 960.047 1009.62 965.461 1022.44 965.674 C 1047.53 966.175 1070.55 949.432 1073.84 923.797 C 1075.62 909.982 1074.99 895.459 1074.95 881.507 L 1074.69 816.996 L 1075.06 596.563 z")

    static let ears: CGPath = {
        let path = CGMutablePath()
        path.addPath(svgPath("M 507.446 423.19 C 509.77 423.038 512.098 422.952 514.426 422.931 C 534.526 422.906 547.183 437.998 560.276 450.909 C 568.564 459.084 576.756 467.368 584.978 475.611 L 684.884 576.473 C 630.796 592.882 600.345 607.08 554.365 639.912 C 522.765 662.333 485.141 698.383 463.579 730.706 C 462.532 716.678 463.073 693.687 463.065 679.23 L 463.085 584.988 L 463.048 513.315 C 463.049 475.092 458.065 432.674 507.446 423.19 z"))
        path.addPath(svgPath("M 1529.01 423.248 C 1554.54 420.83 1580.64 439.049 1583.43 464.067 C 1586.68 493.071 1585.17 526.809 1585.13 556.043 L 1585.18 729.358 C 1560.9 699.074 1533.54 671.406 1503.52 646.803 C 1461.09 611.711 1415.97 592.996 1364.19 576.284 C 1397.4 542.106 1430.97 508.279 1464.9 474.809 C 1479.83 459.906 1496.14 442.247 1512.37 428.805 C 1515.94 425.849 1524.24 424.172 1529.01 423.248 z"))
        return path
    }()

    /// The two round eyes (drawn in Harbor on the logo; holes in the template icon).
    static let eyes: [CGRect] = [
        CGRect(x: 21.53, y: 34.517, width: 5.022, height: 5.022),
        CGRect(x: 37.398, y: 34.468, width: 5.127, height: 5.127),
    ]

    /// Head, ears and eye holes: fill with the even-odd rule.
    static let silhouette: CGPath = {
        let path = CGMutablePath()
        path.addPath(head)
        path.addPath(ears)
        eyes.forEach { path.addEllipse(in: $0) }
        return path
    }()

    /// Parses the logo's absolute M/L/C/Z path data (2048 units) into 64 units.
    private static func svgPath(_ data: String) -> CGPath {
        let path = CGMutablePath()
        let tokens = data.split(separator: " ")
        var index = 0
        var command: Character = "M"
        func number() -> CGFloat {
            defer { index += 1 }
            return CGFloat(Double(tokens[index]) ?? 0) / 32
        }
        func point() -> CGPoint { CGPoint(x: number(), y: number()) }
        while index < tokens.count {
            if let first = tokens[index].first, first.isLetter {
                command = first
                index += 1
                if command == "Z" || command == "z" { path.closeSubpath(); continue }
            }
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "C":
                let control1 = point(), control2 = point(), end = point()
                path.addCurve(to: end, control1: control1, control2: control2)
            default: index += 1
            }
        }
        return path
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
    // brand/README.md: Harbor ground, Foam text, Marmalade (the cat) as the one accent.
    static let harbor = NSColor(hexString: "#0f3a3c")!
    static let foam = NSColor(hexString: "#eef6f2")!
    static let marmalade = NSColor(hexString: "#f4913e")!

    static let github = URL(string: "https://github.com/0xNtive/tabby")!
    static let website = URL(string: "https://claude-tabby.vercel.app")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The menu-bar icon: the cat as a template image, stripes and eyes cut out.
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
    private let eyes = (0..<2).map { _ in CAShapeLayer() }
    private var blinking = false
    private var laidOutSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        body.fillColor = Brand.marmalade.cgColor
        eyes.forEach { $0.fillColor = Brand.harbor.cgColor }
        for sublayer in [body] + eyes {
            sublayer.actions = noActions
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private let noActions: [String: CAAction] = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                                 "transform": NSNull()]

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize, bounds.width > 0 else { return }
        laidOutSize = bounds.size
        var (transform, _) = CatGeometry.transform(fitting: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shape = CGMutablePath()
        shape.addPath(CatGeometry.head)
        shape.addPath(CatGeometry.ears)
        body.path = shape.copy(using: &transform)
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
