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
    var id: String { key }
}

struct ThemeInfo: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let mode: String
    let bg: String
    let fg: String
    let accents: [Accent]
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
}

// MARK: - Colors

enum Palette {
    static let neutralHex = "#8a8f98"
    static let waitingNS = NSColor(srgbRed: 1.0, green: 0.63, blue: 0.22, alpha: 1)
    static let dangerNS = NSColor(srgbRed: 0.96, green: 0.38, blue: 0.38, alpha: 1)
    static let warnNS = NSColor(srgbRed: 0.98, green: 0.76, blue: 0.30, alpha: 1)
    static let waiting = Color(nsColor: waitingNS)
    static let danger = Color(nsColor: dangerNS)
    static let warn = Color(nsColor: warnNS)

    /// Offered in the Color menu until tabby has written themes.json.
    static let fallbackAccents: [Accent] = [
        Accent(key: "red", hex: "#e8868b"),
        Accent(key: "orange", hex: "#e9a36f"),
        Accent(key: "yellow", hex: "#d9c27a"),
        Accent(key: "green", hex: "#96c98b"),
        Accent(key: "teal", hex: "#6fc7bd"),
        Accent(key: "blue", hex: "#7fb0ea"),
        Accent(key: "purple", hex: "#b89ae6"),
        Accent(key: "pink", hex: "#e39bc6"),
    ]
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
