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

    // MARK: Minimal: dot, title, status, context (30 pt)

    private var minimal: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            HStack(spacing: 10) {
                PulseDot(hex: session.dotHex, status: session.status, dotSize: 8, reduceMotion: reduceMotion)
                    .frame(width: 16, height: 16)
                if let renameText {
                    RenameField(text: renameText, size: 12.5, onCommit: onRenameCommit, onCancel: onRenameCancel)
                } else {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(session.status.isYourTurn ? 0.8 : 0.96))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if hovered && renameText == nil { menuButton(size: 16).transition(.opacity) }
                StatusLabel(session: session, now: context.date, chip: false)
                ContextGauge(pct: session.contextPct, reduceMotion: reduceMotion)
                    .frame(width: 46, alignment: .trailing)
            }
            .frame(height: 16)
        }
    }

    // MARK: Standard: title and status, project · model, context; progress while working

    private var standard: some View {
        HStack(alignment: .top, spacing: 10) {
            PulseDot(hex: session.dotHex, status: session.status, dotSize: 9, reduceMotion: reduceMotion)
                .frame(width: 18, height: 18)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    titleLine(now: context.date, detail: false)
                    HStack(spacing: 8) {
                        secondaryLine(now: context.date)
                        Spacer(minLength: 6)
                        ContextGauge(pct: session.contextPct, label: "context", reduceMotion: reduceMotion)
                    }
                    if let guess = session.progress(now: context.date) {
                        ProgressLine(guess: guess, accent: dot, reduceMotion: reduceMotion)
                            .padding(.top, 2)
                    }
                    if hovered {
                        VStack(alignment: .leading, spacing: 5) {
                            currentTask
                            summaryBlock(lines: 4)
                            noteBlock
                            promptBlock(lines: 2)
                        }
                        .padding(.top, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    // MARK: Detailed: everything, always

    private var detailed: some View {
        HStack(alignment: .top, spacing: 10) {
            PulseDot(hex: session.dotHex, status: session.status, dotSize: 9, reduceMotion: reduceMotion)
                .frame(width: 18, height: 18)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    titleLine(now: context.date, detail: true)
                    HStack(spacing: 8) {
                        secondaryLine(now: context.date)
                            .layoutPriority(-1)
                        Spacer(minLength: 6)
                        ContextGauge(pct: session.contextPct, label: "context", caption: session.usageLine,
                                     reduceMotion: reduceMotion)
                    }
                    if let guess = session.progress(now: context.date) {
                        ProgressLine(guess: guess, accent: dot, reduceMotion: reduceMotion)
                            .padding(.vertical, 2)
                    }
                    currentTask
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

    private func titleLine(now: Date, detail: Bool) -> some View {
        HStack(spacing: 8) {
            if let renameText {
                RenameField(text: renameText, size: 13, onCommit: onRenameCommit, onCancel: onRenameCancel)
            } else {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(session.status.isYourTurn ? 0.84 : 1))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
            if hovered && renameText == nil { menuButton(size: 18).transition(.opacity) }
            StatusLabel(session: session, now: now, detail: detail)
        }
        .frame(height: 18)
    }

    /// project · model, then when it finished or asked.
    private func secondaryLine(now: Date) -> some View {
        let when: String?
        switch session.status {
        case .idle, .unknown: when = Fmt.ago(session.activityAt, now: now).map { "done \($0)" }
        case .waiting: when = Fmt.ago(session.activityAt, now: now).map { "asked \($0)" }
        case .error: when = Fmt.ago(session.activityAt, now: now)
        default: when = nil
        }
        return Text([session.project, session.model, when]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.58))
            .lineLimit(1)
    }

    /// The task Claude is on, from its task list.
    @ViewBuilder private var currentTask: some View {
        if session.status == .busy, let task = session.tasks?.current {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(task)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
        }
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

// MARK: - Status label ("Working 3m", "Your turn", "Needs you · permission", "Error")

/// What a session is doing, in words and a color of its own: white while working, green on
/// your turn, amber when it needs you, red on an error.
struct StatusLabel: View {
    let session: IslandSession
    let now: Date
    /// "Needs you · permission" rather than "Needs you".
    var detail = false
    /// A tinted capsule; plain colored text in the one-line mode.
    var chip = true

    var body: some View {
        let (text, color, symbol) = label
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .heavy))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.horizontal, chip ? 7 : 0)
        .frame(height: 18)
        .background(Capsule().fill(color.opacity(chip ? 0.14 : 0)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var label: (String, Color, String?) {
        switch session.status {
        case .busy:
            let worked = session.workElapsed(now: now).flatMap(Fmt.worked)
            return (worked.map { "Working \($0)" } ?? "Working", Color.white.opacity(0.9), nil)
        case .waiting:
            let what = detail ? session.waitingFor.map { Fmt.oneLine($0.lowercased(), max: 24) } : nil
            return (what.map { "Needs you · \($0)" } ?? "Needs you", Palette.waiting, "bell.fill")
        case .idle, .unknown:
            return ("Your turn", Palette.done, "checkmark")
        case .error:
            return ("Error", Palette.danger, "exclamationmark.triangle.fill")
        case .new:
            return ("New", Color.white.opacity(0.7), nil)
        case .ended:
            return ("Ended", Color.white.opacity(0.5), nil)
        }
    }
}

// MARK: - Context gauge

/// How much of the context window is used: a small ring and a percentage. It isn't progress,
/// so it isn't a bar. Amber from 70 %, red from 90 %.
struct ContextGauge: View {
    let pct: Double?
    /// "context" after the percentage, where there's room.
    var label: String? = nil
    /// Detailed mode: "452k / 1M tokens · $3.20".
    var caption: String? = nil
    let reduceMotion: Bool

    var body: some View {
        if pct != nil { gauge }
    }

    private var gauge: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 2)
                if let pct {
                    Circle()
                        .trim(from: 0, to: CGFloat(min(max(pct, 0), 100) / 100))
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 10, height: 10)
            Percent(pct: pct, reduceMotion: reduceMotion, tinted: true)
            if let label, pct != nil {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if let caption, !caption.isEmpty {
                Text("·").foregroundStyle(.white.opacity(0.35))
                Text(caption)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(pct.map { "Context window \(Int($0.rounded()))% used" } ?? "Context usage unknown")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pct.map { "Context \(Int($0.rounded())) percent used" } ?? "Context usage unknown")
    }

    private var color: Color {
        guard let pct else { return .white.opacity(0.35) }
        if pct >= 90 { return Palette.danger }
        if pct >= 70 { return Palette.warn }
        return .white.opacity(0.7)
    }
}

// MARK: - Progress line

/// A working session's guesstimate: a thin bar in its color, and "2 of 5 tasks · ~3m left" or
/// "~2m left · usually 4m".
struct ProgressLine: View {
    let guess: ProgressGuess
    let accent: Color
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let fraction = guess.fraction {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(accent)
                            .frame(width: max(4, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
                    }
                }
                .frame(height: 4)
                .frame(minWidth: 60)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: fraction)
            }
            Text(guess.caption)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated progress: \(guess.caption)")
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
