import AppKit
import SwiftUI

// MARK: - Session row (one view, three densities)

struct SessionRow: View {
    let session: IslandSession
    let mode: IslandMode
    /// Hovered by the mouse or selected with the keyboard.
    let hovered: Bool
    let reduceMotion: Bool
    /// Set while this row's title is being edited in place.
    var renameText: Binding<String>? = nil
    var onRenameCommit: () -> Void = {}
    var onRenameCancel: () -> Void = {}
    let onTap: () -> Void
    let onMenu: () -> Void

    private var dot: Color { Color(hexString: session.dotHex) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: mode == .minimal ? 10 : 12, style: .continuous)
    }

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.white.opacity(hovered ? 0.08 : 0)))
            .contentShape(shape)
            .onTapGesture { if renameText == nil { onTap() } }
            .overlay(RightClickCatcher { _ in onMenu() })
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(session.title), \(session.project), \(session.statusDetail)")
            .accessibilityAddTraits(.isButton)
    }

    private var verticalPadding: CGFloat {
        switch mode {
        case .minimal: return 7
        case .standard: return 8
        case .detailed: return 10
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .minimal: minimal
        case .standard: standard
        case .detailed: detailed
        }
    }

    // MARK: Minimal: dot, title, percentage (30 pt)

    private var minimal: some View {
        HStack(spacing: 10) {
            PulseDot(hex: session.dotHex, status: session.status, dotSize: 8, reduceMotion: reduceMotion)
                .frame(width: 16, height: 16)
            if let renameText {
                RenameField(text: renameText, size: 12.5, onCommit: onRenameCommit, onCancel: onRenameCancel)
            } else {
                Text(session.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if hovered && renameText == nil { menuButton(size: 16).transition(.opacity) }
            // No bar in this mode, so the number carries the bar's warning colors.
            Percent(pct: session.contextPct, reduceMotion: reduceMotion, tinted: true)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: 16)
    }

    // MARK: Standard: title, project · model · ago, context bar; hover for the rest

    private var standard: some View {
        HStack(alignment: .top, spacing: 10) {
            PulseDot(hex: session.dotHex, status: session.status, dotSize: 9, reduceMotion: reduceMotion)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                titleLine(chip: false)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    secondaryLine(now: context.date)
                }
                ContextBar(pct: session.contextPct, accent: dot, reduceMotion: reduceMotion)
                    .padding(.top, 2)
                if hovered {
                    VStack(alignment: .leading, spacing: 5) {
                        summaryBlock(lines: 4)
                        noteBlock
                        promptBlock(lines: 2)
                        statusLine
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: Detailed: everything, always

    private var detailed: some View {
        HStack(alignment: .top, spacing: 10) {
            PulseDot(hex: session.dotHex, status: session.status, dotSize: 9, reduceMotion: reduceMotion)
                .frame(width: 18, height: 18)
            TimelineView(.periodic(from: .now, by: 15)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    titleLine(chip: true, now: context.date)
                    secondaryLine(now: context.date)
                    if session.contextPct != nil || session.usageLine != nil {
                        ContextBar(pct: session.contextPct, accent: dot, caption: session.usageLine ?? "",
                                   reduceMotion: reduceMotion)
                            .padding(.vertical, 2)
                    }
                    if session.summary != nil || session.note != nil || session.lastPrompt != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            summaryBlock(lines: 2)
                            noteBlock
                            promptBlock(lines: 1)
                        }
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func titleLine(chip: Bool, now: Date = Date()) -> some View {
        HStack(spacing: 8) {
            if let renameText {
                RenameField(text: renameText, size: 13, onCommit: onRenameCommit, onCancel: onRenameCancel)
            } else {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            if chip { StatusChip(session: session, now: now) }
            Spacer(minLength: 4)
            if hovered && renameText == nil { menuButton(size: 18).transition(.opacity) }
        }
        .frame(height: 18)
    }

    private func secondaryLine(now: Date) -> some View {
        Text([session.project, session.model, Fmt.ago(session.activityAt, now: now)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.58))
            .lineLimit(1)
    }

    @ViewBuilder private func summaryBlock(lines: Int) -> some View {
        if let summary = session.summary {
            Text(summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var noteBlock: some View {
        if let note = session.note {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "note.text")
                    .font(.system(size: 10, weight: .medium))
                Text(note)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.72))
        }
    }

    @ViewBuilder private func promptBlock(lines: Int) -> some View {
        if let prompt = session.lastPrompt {
            Text("“\(prompt)”")
                .font(.system(size: 11).italic())
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(lines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 5) {
            Image(systemName: session.status.symbol)
            Text([session.statusDetail, session.usageLine].compactMap { $0 }.joined(separator: " · "))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(statusColor)
        .lineLimit(1)
    }

    private var statusColor: Color {
        switch session.status {
        case .waiting: return Palette.waiting
        case .error: return Palette.danger
        default: return Color.white.opacity(0.58)
        }
    }

    private func menuButton(size: CGFloat) -> some View {
        Button(action: onMenu) {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: size - 4))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rename, color, theme…")
    }
}

// MARK: - Inline rename field

/// The title, editable: Return renames (empty lets AI name it), Esc cancels.
struct RenameField: View {
    @Binding var text: String
    let size: CGFloat
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("Empty lets AI name it").foregroundStyle(.white.opacity(0.4)))
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .focused($focused)
            .onSubmit(onCommit)
            .onExitCommand(perform: onCancel)
            .padding(.horizontal, 6)
            .frame(height: size + 9)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
            .padding(.leading, -6)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .accessibilityLabel("New name for this tab")
    }
}

// MARK: - Status chip ("working 4m", "your turn", "needs you · permission")

struct StatusChip: View {
    let session: IslandSession
    let now: Date

    var body: some View {
        let (text, color) = label
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 17)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize()
            .accessibilityLabel(text)
    }

    private var label: (String, Color) {
        switch session.status {
        case .busy:
            let elapsed = Fmt.elapsed(session.activityAt, now: now)
            return (elapsed.map { "working \($0)" } ?? "working", Color.white.opacity(0.75))
        case .waiting:
            let what = session.waitingFor.map { Fmt.oneLine($0.lowercased(), max: 24) }
            return (what.map { "needs you · \($0)" } ?? "needs you", Palette.waiting)
        case .idle, .unknown:
            return ("your turn", Palette.done)
        case .error:
            return ("error", Palette.danger)
        case .new:
            return ("new", Color.white.opacity(0.75))
        case .ended:
            return ("ended", Color.white.opacity(0.55))
        }
    }
}

// MARK: - Context bar

struct ContextBar: View {
    let pct: Double?
    let accent: Color
    /// Detailed mode: "452k / 1M tokens · $3.20" after the percentage.
    var caption: String?
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    if let pct {
                        Capsule()
                            .fill(color(for: pct))
                            .frame(width: max(4, proxy.size.width * CGFloat(min(max(pct, 0), 100) / 100)))
                    }
                }
            }
            .frame(height: 4)
            .frame(minWidth: 60)
            if let caption, !caption.isEmpty {
                HStack(spacing: 5) {
                    Percent(pct: pct, reduceMotion: reduceMotion)
                    Text("·").foregroundStyle(.white.opacity(0.4))
                    Text(caption)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.62))
                }
                .lineLimit(1)
                .fixedSize()
            } else {
                Percent(pct: pct, reduceMotion: reduceMotion)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .frame(height: 13)
        .accessibilityElement()
        .accessibilityLabel(pct.map { "Context \(Int($0.rounded())) percent used" } ?? "Context usage unknown")
    }

    private func color(for pct: Double) -> Color {
        if pct >= 90 { return Palette.danger }
        if pct >= 70 { return Palette.warn }
        return accent
    }
}

/// "48%" that rolls its digits when the number changes.
struct Percent: View {
    let pct: Double?
    let reduceMotion: Bool
    var tinted = false

    private var color: Color {
        guard let pct else { return .white.opacity(0.35) }
        if tinted && pct >= 90 { return Palette.danger }
        if tinted && pct >= 70 { return Palette.warn }
        return .white.opacity(0.66)
    }

    var body: some View {
        let value = pct.map { Int($0.rounded()) }
        Text(value.map { "\($0)%" } ?? "—")
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(value ?? 0)))
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: value)
    }
}

// MARK: - Entrance: rows fade and slide in with a small stagger

struct StaggeredEntrance: ViewModifier {
    let index: Int
    let enabled: Bool
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || !enabled ? 1 : 0)
            .offset(y: shown || !enabled || reduceMotion ? 0 : -8)
            .onAppear {
                guard enabled, !shown else { return }
                let delay = 0.04 + Double(min(index, 10)) * 0.035
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.18).delay(delay)
                    : .spring(response: 0.36, dampingFraction: 0.82).delay(delay)
                withAnimation(animation) { shown = true }
            }
    }
}
