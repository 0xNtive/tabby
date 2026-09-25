import AppKit
import SwiftUI

// MARK: - Session status

enum SessionStatus: String, Equatable, Sendable {
    case busy, idle, waiting, error, new, ended, unknown

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "busy", "working", "running", "thinking": self = .busy
        case "idle", "ready", "done": self = .idle
        case "waiting", "attention", "blocked", "needs_input": self = .waiting
        case "error", "failed": self = .error
        case "new", "starting": self = .new
        case "ended", "exited", "stopped": self = .ended
        default: self = .unknown
        }
    }

    /// Order in the expanded list: sessions that need you come first.
    var sortRank: Int {
        switch self {
        case .waiting: return 0
        case .error: return 1
        case .busy: return 2
        default: return 3
        }
    }

    var symbol: String {
        switch self {
        case .busy: return "circle.dotted"
        case .waiting: return "bell.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle, .unknown: return "checkmark.circle"
        case .new: return "sparkle"
        case .ended: return "stop.circle"
        }
    }

    /// The turn is over and Claude waits for your next prompt.
    var isYourTurn: Bool { self == .idle || self == .unknown }
}

// MARK: - Island settings (the island's keys in ~/.claude/tabby/config.json)

/// How much the expanded island shows per session (`islandMode`).
enum IslandMode: String, CaseIterable, Identifiable, Sendable {
    case minimal, standard, detailed

    init?(raw: String?) {
        guard let raw, let mode = IslandMode(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return nil
        }
        self = mode
    }

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .minimal: return "line.3.horizontal"
        case .standard: return "rectangle.grid.1x2"
        case .detailed: return "list.bullet.below.rectangle"
        }
    }

    var help: String {
        switch self {
        case .minimal: return "Minimal — one line per session"
        case .standard: return "Standard — title, project and context; hover a row for more"
        case .detailed: return "Detailed — status, context, summary and last prompt for every session"
        }
    }

    var next: IslandMode {
        let all = IslandMode.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }

    /// Width of the expanded island.
    var width: CGFloat {
        switch self {
        case .minimal: return 416
        case .standard: return 480
        case .detailed: return 512
        }
    }
}

struct IslandConfig: Equatable, Sendable {
    var mode: IslandMode = .standard
    /// Live-activity announcements in the collapsed pill (`islandAnnounce`).
    var announce = true
    /// Global ⌃⌥ shortcuts (`islandHotkeys`).
    var hotkeys = true
}

// MARK: - Announcements (live activities in the collapsed pill)

struct Announcement: Equatable, Identifiable {
    enum Kind: Equatable { case done, waiting, info }

    let id = UUID()
    var kind: Kind
    /// The bold part: a session title, or the whole message.
    var title: String
    /// Colored tail after the title ("is done", "needs you").
    var suffix: String?
    var symbol: String
    var sessionId: String?
    /// A newer announcement on the same topic replaces this one instead of queueing
    /// (the same session, the mode shortcut, tiling).
    var topic: String?
    /// Tooltip with the full text when the pill had to shorten it.
    var detail: String?
    /// Clicking opens System Settings › Privacy & Security › Accessibility.
    var opensAccessibility = false

    static func done(_ session: IslandSession) -> Announcement {
        Announcement(kind: .done, title: session.title, suffix: "is done", symbol: "checkmark.circle.fill",
                     sessionId: session.id, topic: session.id)
    }

    static func waiting(_ session: IslandSession) -> Announcement {
        Announcement(kind: .waiting, title: session.title, suffix: "needs you", symbol: "bell.fill",
                     sessionId: session.id, topic: session.id)
    }

    static func info(_ text: String, symbol: String = "info.circle.fill", topic: String? = nil,
                      detail: String? = nil, opensAccessibility: Bool = false) -> Announcement {
        Announcement(kind: .info, title: text, suffix: opensAccessibility ? "›" : nil, symbol: symbol, sessionId: nil,
                     topic: topic, detail: detail, opensAccessibility: opensAccessibility)
    }

    var tint: Color {
        switch kind {
        case .done: return Palette.done
        case .waiting: return Palette.waiting
        case .info: return opensAccessibility ? Palette.waiting : Color.white.opacity(0.72)
        }
    }

    /// How long it stays up (hovering holds it).
    var duration: Double {
        if opensAccessibility { return 8 }
        return kind == .info ? 2.6 : 4.2
    }
}

// MARK: - Data

struct ContextUsage: Equatable, Sendable {
    var usedPct: Double?
    var usedTokens: Int?
    var windowSize: Int?
    var costUsd: Double?
    var model: String?
    var at: Double?
}

struct Accent: Equatable, Identifiable, Sendable {
    let key: String
    let hex: String
    /// The accent lifted to at least 4:1 contrast on black: what dots and swatches use.
    let dot: String
    var id: String { key }
}

struct ThemeGroup: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct ThemeInfo: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let mode: String
    let group: String
    let bg: String
    let fg: String
    let accents: [Accent]
    let blurb: String
}

struct CLIConfig: Equatable, Sendable {
    var node: String
    var cli: String
}

struct IslandSession: Equatable, Identifiable, Sendable {
    var id: String
    var sessionId: String?
    var pid: Int
    var cwd: String
    var project: String
    var registryName: String?
    var title: String
    var titleSource: String?
    var summary: String?
    var note: String?
    var theme: String?
    var accentKey: String?
    var accentHex: String?
    /// `dot` from tabby (else the accent lifted to 4:1 on black): every dot and bar on the island.
    var dotHex: String?
    /// The accent as tabby paints the terminal cursor (contrast-checked against the tab).
    var cursorHex: String?
    var status: SessionStatus
    var waitingFor: String?
    var lastPrompt: String?
    var context: ContextUsage?
    var model: String?
    var tty: String?
    var term: String?
    var startedAt: Double
    var activityAt: Double?
    var hasRecord: Bool

    /// What the tabby CLI accepts for `--session`.
    var cliTarget: String { sessionId ?? String(pid) }

    var contextPct: Double? {
        if let pct = context?.usedPct { return pct }
        if let used = context?.usedTokens, let window = context?.windowSize, window > 0 {
            return Double(used) / Double(window) * 100
        }
        return nil
    }

    var statusDetail: String {
        switch status {
        case .busy: return "Working…"
        case .idle, .unknown: return "Idle · your turn"
        case .waiting:
            if let what = waitingFor, !what.isEmpty { return "Waiting for \(what)" }
            return "Waiting for you"
        case .error: return "Stopped with an error"
        case .new: return "New session"
        case .ended: return "Ended"
        }
    }

    /// "452k / 1M tokens · $3.20"
    var usageLine: String? {
        var parts: [String] = []
        if let used = context?.usedTokens {
            if let window = context?.windowSize {
                parts.append("\(Fmt.tokens(used)) / \(Fmt.tokens(window)) tokens")
            } else {
                parts.append("\(Fmt.tokens(used)) tokens")
            }
        }
        if let cost = context?.costUsd, cost > 0 { parts.append(Fmt.cost(cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Colors

enum Palette {
    static let neutralHex = "#8a8f98"
    static let waitingNS = NSColor(srgbRed: 1.0, green: 0.63, blue: 0.22, alpha: 1)
    static let doneNS = NSColor(srgbRed: 0.45, green: 0.86, blue: 0.56, alpha: 1)
    static let dangerNS = NSColor(srgbRed: 0.96, green: 0.38, blue: 0.38, alpha: 1)
    static let warnNS = NSColor(srgbRed: 0.98, green: 0.76, blue: 0.30, alpha: 1)
    static let waiting = Color(nsColor: waitingNS)
    static let done = Color(nsColor: doneNS)
    static let danger = Color(nsColor: dangerNS)
    static let warn = Color(nsColor: warnNS)

    /// Offered in the Color menu until tabby has written themes.json.
    static let fallbackAccents: [Accent] = [
        ("red", "#e8868b"), ("orange", "#e9a36f"), ("yellow", "#d9c27a"), ("green", "#96c98b"),
        ("teal", "#6fc7bd"), ("blue", "#7fb0ea"), ("purple", "#b89ae6"), ("pink", "#e39bc6"),
    ].map { Accent(key: $0.0, hex: $0.1, dot: ColorMath.onBlack($0.1) ?? $0.1) }
}

extension NSColor {
    /// Parses `#rgb`, `#rrggbb` or `#rrggbbaa` as sRGB.
    convenience init?(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let a = hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension Color {
    init(hexString: String?, fallback: String = Palette.neutralHex) {
        self.init(nsColor: NSColor(hexString: hexString) ?? NSColor(hexString: fallback) ?? .gray)
    }
}

/// OKLab / WCAG math, mirroring tabby's lib/color.js so dots match what the CLI computes.
enum ColorMath {
    static func rgb(_ hex: String?) -> SIMD3<Double>? {
        guard var h = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        if h.count == 8 { h = String(h.prefix(6)) }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return SIMD3(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    static func hex(_ c: SIMD3<Double>) -> String {
        func byte(_ x: Double) -> Int { Int((Swift.min(Swift.max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.x), byte(c.y), byte(c.z))
    }

    private static func toLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func fromLinear(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    static func luminance(_ c: SIMD3<Double>) -> Double {
        0.2126 * toLinear(c.x) + 0.7152 * toLinear(c.y) + 0.0722 * toLinear(c.z)
    }

    static func contrastOnBlack(_ c: SIMD3<Double>) -> Double { (luminance(c) + 0.05) / 0.05 }

    private static func oklab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let r = toLinear(c.x), g = toLinear(c.y), b = toLinear(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
    }

    private static func linear(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.291485548 * lab.z, 3)
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s)
    }

    private static func inGamut(_ c: SIMD3<Double>) -> Bool {
        [c.x, c.y, c.z].allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 }
    }

    /// OKLab → hex, reducing chroma (keeping lightness and hue) until it fits sRGB.
    private static func hex(oklab lab: SIMD3<Double>) -> String {
        var lin = linear(lab)
        if !inGamut(lin) {
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if inGamut(linear(SIMD3(lab.x, lab.y * mid, lab.z * mid))) { lo = mid } else { hi = mid }
            }
            lin = linear(SIMD3(lab.x, lab.y * lo, lab.z * lo))
        }
        return hex(SIMD3(fromLinear(Swift.min(Swift.max(lin.x, 0), 1)),
                         fromLinear(Swift.min(Swift.max(lin.y, 0), 1)),
                         fromLinear(Swift.min(Swift.max(lin.z, 0), 1))))
    }

    /// tabby's `onBlack`: raise OKLCH lightness in 0.02 steps until the color reaches
    /// `ratio`:1 contrast against #000.
    static func onBlack(_ hexString: String?, ratio: Double = 4) -> String? {
        guard let color = rgb(hexString) else { return nil }
        if contrastOnBlack(color) >= ratio { return hex(color) }
        let lab = oklab(color)
        let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        let hue = atan2(lab.z, lab.y)
        for step in 1...50 {
            let lightness = Swift.min(1, Swift.max(0, lab.x + Double(step) * 0.02))
            let candidate = hex(oklab: SIMD3(lightness, chroma * cos(hue), chroma * sin(hue)))
            if let rgb = rgb(candidate), contrastOnBlack(rgb) >= ratio { return candidate }
        }
        return "#ffffff"
    }
}

enum Hue {
    /// Orders accents like a rainbow (reds first), with grays last.
    static func sortKey(_ hex: String) -> (Int, Double) {
        guard let color = NSColor(hexString: hex)?.usingColorSpace(.sRGB) else { return (2, 0) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return (1, Double(b)) }
        return (0, Double(h > 0.96 ? h - 1 : h))
    }

    static func ordered(_ x: Accent, _ y: Accent) -> Bool {
        let a = sortKey(x.hex), b = sortKey(y.hex)
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        return x.key < y.key
    }
}

// MARK: - Formatting

enum Fmt {
    static func ago(_ ms: Double?, now: Date) -> String? {
        guard let ms, ms > 0 else { return nil }
        let seconds = max(0, now.timeIntervalSince1970 - ms / 1000)
        if seconds < 45 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// "4m", "2h", "3d" since a timestamp; nil under a minute.
    static func elapsed(_ ms: Double?, now: Date) -> String? {
        guard let ms, ms > 0 else { return nil }
        let minutes = Int(max(0, now.timeIntervalSince1970 - ms / 1000) / 60)
        if minutes < 1 { return nil }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
        return "\(n)"
    }

    static func cost(_ usd: Double) -> String { usd < 0.01 ? "<$0.01" : String(format: "$%.2f", usd) }

    /// "claude-opus-5-5[1m]" → "Opus 5.5"; display names pass through untouched.
    static func prettyModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("claude") else {
            // "Opus 5.5 (1M context)" → "Opus 5.5"; the window size is in the row's details.
            if let paren = trimmed.range(of: " (") { return String(trimmed[..<paren.lowerBound]) }
            return trimmed
        }
        var id = trimmed.replacingOccurrences(of: "[1m]", with: "")
        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
        var parts = id.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first(where: { Int($0) == nil }) else { return trimmed }
        let version = parts.filter { Int($0) != nil && $0.count <= 2 }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    static func oneLine(_ text: String, max: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > max ? String(collapsed.prefix(max)) + "…" : collapsed
    }
}

/// Text widths for layout that SwiftUI can't measure ahead of time (the announcement pill).
enum TextMetrics {
    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }
}
