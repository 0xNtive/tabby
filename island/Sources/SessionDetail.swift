import AppKit
import SwiftUI

// MARK: - Which row's dropdown is open

/// The hover dropdown under a session row: it opens once the pointer rests on a row for a
/// moment (so sweeping across the list doesn't flicker cards open), follows the pointer to the
/// next row, and closes a moment after the pointer leaves. It also holds the inline "End
/// session" confirmation and what came of it. One-shot timers only: nothing runs while idle.
@MainActor
final class SessionDetailModel: ObservableObject {
    static let shared = SessionDetailModel()

    struct Notice: Equatable {
        let text: String
        let ok: Bool
    }

    struct Failure: Equatable {
        let id: String
        let message: String
    }

    @Published private(set) var openRow: String?
    @Published private(set) var confirming: String?
    /// The confirmation's End Session button takes clicks (a moment after it appears).
    @Published private(set) var confirmArmed = false
    private var confirmShownAt: Date?
    private var armWork: DispatchWorkItem?
    @Published private(set) var ending: Set<String> = []
    @Published private(set) var failure: Failure?
    /// A line under the list after a session ends ("Ended “Auth refactor”").
    @Published private(set) var notice: Notice?
    var reduceMotion = false
    /// Says a failure in the island too: the card that shows it can close before you see it.
    var announceFailure: ((String) -> Void)?

    static let openDelay: TimeInterval = 0.25
    static let closeGrace: TimeInterval = 0.2
    private var pending: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)
    }

    /// The row under the pointer (or picked with the arrow keys) changed.
    func pointer(at id: String?) {
        pending?.cancel()
        pending = nil
        guard id != openRow else { return }
        // A card that's confirming or ending stays put while the pointer only slips off it.
        if id == nil, let open = openRow, confirming == open || ending.contains(open) { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.open(id) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (id == nil ? Self.closeGrace : Self.openDelay), execute: work)
    }

    private func open(_ id: String?) {
        pending = nil
        withAnimation(animation) {
            openRow = id
            if confirming != id { confirming = nil }
            if failure?.id != id { failure = nil }
        }
    }

    /// The island collapsed: every card closes; a confirmation left open is a Cancel.
    func reset() {
        pending?.cancel()
        pending = nil
        openRow = nil
        confirming = nil
        failure = nil
    }

    func askToEnd(_ session: IslandSession) {
        pending?.cancel()
        pending = nil
        withAnimation(animation) {
            openRow = session.id
            confirming = session.id
            failure = nil
        }
        confirmShownAt = Date()
        confirmArmed = false
        armWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.confirming == session.id else { return }
                withAnimation(.easeOut(duration: 0.15)) { self.confirmArmed = true }
            }
        }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SessionEndGuard.armDelay(doubleClickInterval: NSEvent.doubleClickInterval),
                                      execute: work)
    }

    func cancelEnd() {
        withAnimation(animation) { confirming = nil }
    }

    func dismissFailure() {
        withAnimation(animation) { failure = nil }
    }

    /// Only from the confirmation's "End Session" button, once it's been up a moment.
    func end(_ session: IslandSession, store: SessionStore?) {
        guard confirming == session.id, !ending.contains(session.id),
              SessionEndGuard.confirmAccepts(shownAt: confirmShownAt, now: Date(), doubleClickInterval: NSEvent.doubleClickInterval)
        else { return }
        withAnimation(animation) {
            confirming = nil
            ending.insert(session.id)
        }
        SessionEnder.end(session) { [weak self] outcome in
            guard let self else { return }
            withAnimation(self.animation) {
                self.ending.remove(session.id)
                switch outcome {
                case .ended(let closed, let note):
                    if self.openRow == session.id { self.openRow = nil }
                    let what = closed ? "Ended “\(session.title)” and closed its tab." : "Ended “\(session.title)”."
                    self.say(note.map { "\(what) \($0)" } ?? what, ok: true)
                case .gone:
                    if self.openRow == session.id { self.openRow = nil }
                    self.say("“\(session.title)” had already ended.", ok: true)
                case .failed(let message):
                    self.failure = Failure(id: session.id, message: message)
                    self.announceFailure?("Couldn't end “\(session.title)”: \(message)")
                }
            }
            store?.refresh()
        }
    }

    private func say(_ text: String, ok: Bool) {
        notice = Notice(text: text, ok: ok)
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(self.animation) { self.notice = nil }
            }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Snapshot renders: a fixed state, no timers.
    func freeze(open: String?, confirming: String? = nil, ending: Set<String> = [], failure: Failure? = nil,
                notice: Notice? = nil, armed: Bool = true) {
        openRow = open
        self.confirming = confirming
        confirmArmed = armed
        self.ending = ending
        self.failure = failure
        self.notice = notice
    }
}

// MARK: - The dropdown

/// Everything that says what's going on in a session, under its row: what it's doing or
/// waiting for, the summary, the current task, what you last asked, where it runs, and the
/// actions (Open Tab, End Session…).
struct SessionDetailCard: View {
    let session: IslandSession
    let mode: IslandMode
    @ObservedObject var model: SessionDetailModel
    let reduceMotion: Bool
    let onOpen: () -> Void

    private var confirming: Bool { model.confirming == session.id }
    private var ending: Bool { model.ending.contains(session.id) }
    private var failure: String? { model.failure?.id == session.id ? model.failure?.message : nil }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Group {
                if ending {
                    endingView
                } else if confirming {
                    confirmView
                } else if let failure {
                    failureView(failure)
                } else {
                    details(now: context.date)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.34)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(confirming || failure != nil ? Palette.danger.opacity(0.45) : Color.white.opacity(0.07),
                              lineWidth: 1))
        }
    }

    // MARK: Details

    private func details(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            headline(now: now)
            if mode != .detailed {
                if session.status == .busy, let tasks = session.tasks, let task = tasks.current {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 9.5, weight: .semibold))
                        Text(task).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        if tasks.total >= 2 {
                            Text("task \(min(tasks.done + 1, tasks.total)) of \(tasks.total)")
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                }
                if let summary = session.summary {
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = session.note {
                    Label {
                        Text(note).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "note.text").font(.system(size: 10, weight: .medium))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.72))
                }
                if let prompt = session.typedPrompt {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("YOU ASKED")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.38))
                        Text("“\(prompt)”")
                            .font(.system(size: 11).italic())
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            facts(now: now)
            actions
        }
    }

    private func headline(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                statusIcon
                Text(SessionDetailCopy.headline(session, now: now))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let when = SessionDetailCopy.when(session, now: now) {
                    Text(when)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize()
                }
            }
            if let hint = SessionDetailCopy.hint(session, now: now, progress: mode == .minimal) {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if session.status == .busy {
            Spinner(color: NSColor.white.withAlphaComponent(0.85), reduceMotion: reduceMotion)
                .frame(width: 11, height: 11)
                .frame(width: 12)
        } else {
            Image(systemName: statusSymbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 12)
        }
    }

    private var statusSymbol: String {
        switch session.status {
        case .waiting: return "bell.fill"
        case .idle, .unknown: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .new: return "sparkle"
        case .ended: return "stop.circle"
        case .busy: return "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .waiting: return Palette.waiting
        case .idle, .unknown: return Palette.done
        case .error: return Palette.danger
        default: return .white.opacity(0.94)
        }
    }

    /// Where it runs and what it has used, as small facts that wrap.
    private func facts(now: Date) -> some View {
        FlowLayout(spacing: 12, lineSpacing: 5) {
            if let started = Fmt.ago(session.startedAt, now: now) {
                Fact(symbol: "clock", text: "started \(started)")
            }
            if mode == .minimal, let pct = session.contextPct {
                Fact(symbol: "circle.lefthalf.filled", text: "\(Int(pct.rounded()))% context")
            }
            if mode != .detailed, let usage = session.usageLine {
                Fact(symbol: "gauge.with.dots.needle.33percent", text: usage)
            }
            if mode == .minimal, let model = session.model {
                Fact(symbol: "sparkles", text: model)
            }
            if !session.cwd.isEmpty {
                Fact(symbol: "folder", text: SessionDetailCopy.path(session.cwd))
            }
            Fact(symbol: "terminal", text: terminalText)
        }
    }

    private var terminalText: String {
        let label = TerminalKind(term: session.term).label
        guard let tty = SessionEndGuard.normalizeTTY(session.tty) else { return label }
        return "\(label) · \((tty as NSString).lastPathComponent)"
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            DetailButton(title: "Open Tab", symbol: "arrow.up.forward.app", role: .normal, action: onOpen)
                .help("Switch to this session's terminal tab")
            DetailButton(title: "End Session…", symbol: "stop.circle", role: .quietDestructive) { model.askToEnd(session) }
                .help("Stop Claude in this tab (asks first)")
        }
    }

    // MARK: End session

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.danger)
                Text("End “\(session.title)”?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(SessionDetailCopy.endConsequence(session))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                DetailButton(title: "Cancel", symbol: nil, role: .normal) { model.cancelEnd() }
                    .keyboardShortcut(.cancelAction)
                DetailButton(title: "End Session", symbol: nil, role: .destructive) { model.end(session, store: Actions.store) }
                    // Takes the click (so it can't fall through to the row) but acts only once armed.
                    .opacity(model.confirmArmed ? 1 : 0.45)
                    .accessibilityHint(model.confirmArmed ? "" : "Available in a moment")
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("End \(session.title)? \(SessionDetailCopy.endConsequence(session))")
    }

    private var endingView: some View {
        HStack(spacing: 8) {
            Spinner(color: NSColor.white.withAlphaComponent(0.8), reduceMotion: reduceMotion)
                .frame(width: 11, height: 11)
            Text("Ending “\(session.title)”…")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .frame(height: 20)
    }

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.danger)
                Text("Couldn't end “\(session.title)”")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                DetailButton(title: "OK", symbol: nil, role: .normal) { model.dismissFailure() }
            }
        }
    }
}

/// One small fact in the dropdown: an SF Symbol and a short text.
private struct Fact: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text(text)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .fixedSize()
    }
}

struct DetailButton: View {
    enum Role { case normal, quietDestructive, destructive }

    let title: String
    let symbol: String?
    let role: Role
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        switch role {
        case .normal: return .white.opacity(0.88)
        case .quietDestructive: return Palette.danger
        case .destructive: return .white
        }
    }

    private var background: Color {
        switch role {
        case .normal: return .white.opacity(0.11)
        case .quietDestructive: return Palette.danger.opacity(0.13)
        case .destructive: return Palette.danger.opacity(0.9)
        }
    }
}

/// Lays children out left to right and wraps them onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// The line under the list after a session ends.
struct DetailNotice: View {
    let notice: SessionDetailModel.Notice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(notice.ok ? Palette.done : Palette.danger)
            Text(notice.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
