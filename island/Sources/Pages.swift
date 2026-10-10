import AppKit
import SwiftUI

// MARK: - Model

/// History and Processes: loaded through the tabby CLI when their page opens (and processes now
/// and then in the background, for the toolbar's count), acted on from their rows.
@MainActor
final class PagesModel: ObservableObject {
    @Published var history: [PastSession] = []
    @Published var historyLoaded = false
    @Published var historyLoading = false
    /// The session being resumed (a spinner on its row).
    @Published var resuming: String?

    @Published var scan: ProcessScan?
    @Published var scanning = false
    /// Processes being stopped (a spinner on their rows).
    @Published var stopping: Set<String> = []
    /// What the last action did, at the top of the page for a few seconds.
    @Published var notice: (text: String, ok: Bool)? {
        didSet { noticeWork?.cancel() }
    }

    /// Leftovers worth a word in the collapsed pill (set by the controller).
    var onStale: (ProcessScan) -> Void = { _ in }
    private var noticeWork: DispatchWorkItem?
    private var timer: Timer?
    private var historyAt = Date.distantPast
    private let fixed: Bool

    init(fixed: Bool = false) {
        self.fixed = fixed
    }

    var staleCount: Int { scan?.stale.count ?? 0 }

    // MARK: History

    func loadHistory(force: Bool = false) {
        guard !fixed, !historyLoading, force || Date().timeIntervalSince(historyAt) > 5 else { return }
        historyLoading = true
        historyAt = Date()
        Actions.runCLI(["history", "--json", "--limit=80"]) { [weak self] status, output in
            guard let self else { return }
            self.historyLoading = false
            self.historyLoaded = true
            if status == 0, let list = PastSession.parse(output) { self.history = list.filter { !$0.live } }
            Debug.log("history: status \(status), \(self.history.count) past sessions")
        }
    }

    /// `tabby resume <id>`: its tab if it's open, else a new window resuming it.
    func resume(_ session: PastSession, done: @escaping @MainActor (Bool, String) -> Void) {
        guard !fixed, resuming == nil else { return }
        resuming = session.id
        Actions.runCLI(["resume", session.sessionId]) { [weak self] status, output in
            self?.resuming = nil
            let line = output.split(separator: "\n").first.map(String.init) ?? ""
            done(status == 0, line.isEmpty ? "Could not resume “\(session.title)”" : line)
        }
    }

    // MARK: Processes

    /// Every few minutes while the island is up: keeps the toolbar's count true, and finds leftovers.
    func startBackground() {
        guard !fixed, timer == nil else { return }
        let timer = Timer(timeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanProcesses() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self?.scanProcesses() }
        }
    }

    func stopBackground() {
        timer?.invalidate()
        timer = nil
    }

    /// `maxAge`: skip it when the last scan is at least this fresh (seconds).
    func scanProcesses(maxAge: TimeInterval = 0) {
        guard !fixed, !scanning else { return }
        if maxAge > 0, let at = scan?.at, Date().timeIntervalSince1970 * 1000 - at < maxAge * 1000 { return }
        scanning = true
        Actions.runCLI(["procs", "--json"]) { [weak self] status, output in
            guard let self else { return }
            self.scanning = false
            guard status == 0, let next = ProcessScan.parse(output) else {
                Debug.log("procs: status \(status), unreadable output (\(output.prefix(120)))")
                return
            }
            Debug.log("procs: \(next.items.count) found, \(next.stale.count) stale (\(next.items.map { "\($0.label) \($0.why)" }.joined(separator: "; ")))")
            self.scan = next
            self.stopping = self.stopping.filter { id in next.items.contains { $0.id == id } }
            if next.stale.count > 0 { self.onStale(next) }
        }
    }

    /// Stops these (ids from the list as shown: a pid reused since is never hit).
    func stop(_ ids: [String]) {
        guard !fixed, !ids.isEmpty else { return }
        stopping.formUnion(ids)
        Actions.runCLI(["procs", "stop", "--json"] + ids) { [weak self] _, output in
            guard let self else { return }
            if let result = StopResult.parse(output) {
                Debug.log("stop: \(result.message)")
                self.say(result.message, ok: result.failed.isEmpty)
                let gone = Set(result.stopped.map(\.id))
                if var scan = self.scan {
                    scan.items.removeAll { gone.contains($0.id) }
                    let stale = scan.items.filter(\.stale)
                    scan.stale = .init(count: stale.count, memMB: stale.reduce(0) { $0 + $1.memMB },
                                       cpu: stale.reduce(0) { $0 + $1.cpu })
                    self.scan = scan
                }
            } else {
                self.say("Could not stop them", ok: false)
            }
            self.stopping.subtract(ids)
            self.scanProcesses()
        }
    }

    func say(_ text: String, ok: Bool) {
        notice = (text, ok)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.notice = nil }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Snapshot renders.
    func freeze(history: [PastSession]? = nil, scan: ProcessScan? = nil, stopping: Set<String> = [],
                resuming: String? = nil, notice: (String, Bool)? = nil) {
        if let history { self.history = history; historyLoaded = true }
        if let scan { self.scan = scan }
        self.stopping = stopping
        self.resuming = resuming
        self.notice = notice.map { (text: $0.0, ok: $0.1) }
    }
}

// MARK: - Toolbar button

/// History and Processes in the toolbar: lit while their page shows, with a count when it matters.
struct PageButton: View {
    let page: IslandPage
    let active: Bool
    var badge: Int = 0
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: page.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.black.opacity(0.85) : .white.opacity(0.82))
                .frame(width: 26, height: 26)
                .background(Circle().fill(active ? Color.white.opacity(0.88) : Color.white.opacity(0.09)))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(min(badge, 99))")
                            .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Palette.warn))
                            .overlay(Capsule().strokeBorder(Color.black, lineWidth: 1.5))
                            .offset(x: 4, y: -3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Page header

/// "‹ History", what the page is for, and a refresh (or a spinner while loading).
private struct PageHeader: View {
    let page: IslandPage
    let subtitle: String
    let loading: Bool
    let onBack: () -> Void
    let onRefresh: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    Text("Sessions").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to sessions")
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if loading {
                ProgressView().controlSize(.mini).frame(width: 22, height: 22)
            } else if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// A one-line result at the top of a page ("Stopped 3 · freed 1.2 GB").
private struct PageNotice: View {
    let text: String
    let ok: Bool

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(ok ? Palette.done : Palette.warn)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .transition(.opacity)
    }
}

/// A list that hugs its rows, and scrolls only when it has to (like the session list).
private struct PageList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical, showsIndicators: false) { content }
                .mask(ScrollEdgeFade())
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ViewportKey.self, value: proxy.frame(in: .named(IslandSpace.name)))
        })
    }
}

private extension View {
    /// Reports a page row's frame, for the controller's hover tracking.
    func pageRow(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: RowFramesKey.self, value: [id: proxy.frame(in: .named(IslandSpace.name))])
        })
    }
}

// MARK: - History

struct HistoryPage: View {
    @ObservedObject var model: PagesModel
    let hovered: String?
    let onBack: () -> Void
    let onResume: (PastSession) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .history, subtitle: "Click one to go back to it, right where you left off",
                       loading: model.historyLoading && model.historyLoaded, onBack: onBack,
                       onRefresh: { model.loadHistory(force: true) })
            if let notice = model.notice {
                PageNotice(text: notice.text, ok: notice.ok)
            }
            if model.history.isEmpty {
                empty
            } else {
                PageList { rows }
            }
            Color.clear.frame(height: 6)
        }
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: 6) {
            if !model.historyLoaded {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "clock")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.4))
                Text("No past sessions yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                Text("Sessions you close show up here for 30 days.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private var rows: some View {
        let now = Date()
        let groups = Dictionary(grouping: model.history) { $0.day(now: now) }
        let order = ["Today", "Yesterday", "This week", "Earlier"].filter { groups[$0] != nil }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(order, id: \.self) { day in
                Text(day.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.horizontal, 12)
                    .padding(.top, day == order.first ? 2 : 10)
                    .padding(.bottom, 2)
                ForEach(groups[day] ?? []) { session in
                    let rowId = IslandPage.history.rowId(session.id)
                    HistoryRow(session: session, hovered: hovered == rowId, resuming: model.resuming == session.id,
                               now: now) { onResume(session) }
                        .pageRow(rowId)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

private struct HistoryRow: View {
    let session: PastSession
    let hovered: Bool
    let resuming: Bool
    let now: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color(hexString: session.dot ?? session.accent))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                    if !session.detail.isEmpty {
                        Text(session.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                trailing
                    .frame(minWidth: 64, alignment: .trailing)
                    .padding(.top, 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovered ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!session.resumable)
        .opacity(session.resumable ? 1 : 0.5)
        .accessibilityLabel("\(session.title), \(session.detail)")
        .accessibilityHint(session.resumable ? "Resumes this session in a new window" : "Nothing to resume")
    }

    @ViewBuilder private var trailing: some View {
        if resuming {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Opening").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            }
        } else if hovered && session.resumable {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 9.5, weight: .bold))
                Text("Resume").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Palette.done))
            .transition(.opacity)
        } else {
            Text(Fmt.elapsed(session.lastAt, now: now).map { "\($0) ago" } ?? "just now")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.42))
        }
    }
}

// MARK: - Processes

struct ProcessesPage: View {
    @ObservedObject var model: PagesModel
    let hovered: String?
    let onBack: () -> Void

    private var subtitle: String {
        guard let scan = model.scan else { return "Dev servers and leftovers your terminals started" }
        let ago = Fmt.ago(scan.at, now: Date()) ?? "just now"
        return "\(scan.items.count) running · checked \(ago)"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .processes, subtitle: subtitle, loading: model.scanning && model.scan != nil, onBack: onBack,
                       onRefresh: { model.scanProcesses() })
            if let notice = model.notice {
                PageNotice(text: notice.text, ok: notice.ok)
            }
            if let scan = model.scan {
                summary(scan)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                if !scan.items.isEmpty {
                    PageList { rows(scan.items) }
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
            }
            Color.clear.frame(height: 6)
        }
    }

    @ViewBuilder private func summary(_ scan: ProcessScan) -> some View {
        let stale = scan.items.filter(\.stale)
        if stale.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.done)
                VStack(alignment: .leading, spacing: 1) {
                    Text(scan.items.isEmpty ? "Nothing running in the background" : "Nothing stale")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(scan.items.isEmpty
                         ? "No dev servers, leftovers or heavy processes from your terminals."
                         : "Everything here belongs to a session or terminal you still use.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 14))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        } else {
            let busy = stale.contains { model.stopping.contains($0.id) }
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.warn)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(stale.count) stale · \(Fmt.memory(scan.stale.memMB)) · \(Self.cpu(scan.stale.cpu)) CPU")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.94))
                    Text("From closed sessions, or idle for hours")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button {
                    model.stop(stale.map(\.id))
                } label: {
                    HStack(spacing: 5) {
                        if busy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                        }
                        Text(busy ? "Stopping" : stale.count == 1 ? "Stop it" : "Stop all \(stale.count)")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.black.opacity(0.88))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Palette.warn))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("Stop the \(stale.count) stale processes")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.warn.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.warn.opacity(0.25)))
        }
    }

    static func cpu(_ value: Double) -> String {
        value >= 10 || value == value.rounded() ? "\(Int(value.rounded()))%" : String(format: "%.1f%%", value)
    }

    private func rows(_ items: [ProcessItem]) -> some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                let rowId = IslandPage.processes.rowId(item.id)
                ProcessRow(item: item, hovered: hovered == rowId, stopping: model.stopping.contains(item.id)) {
                    model.stop([item.id])
                }
                .pageRow(rowId)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

private struct ProcessRow: View {
    let item: ProcessItem
    let hovered: Bool
    let stopping: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.stale ? Palette.warn : .white.opacity(0.5))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                    if let ports = item.portText {
                        Text(ports)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                // Why it's (not) stale stays whole; the project and session give way first.
                HStack(spacing: 0) {
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .foregroundStyle(.white.opacity(0.5))
                            .truncationMode(.tail)
                        Text(" · ")
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize()
                    }
                    Text(item.why)
                        .foregroundStyle(item.stale ? Palette.warn.opacity(0.9) : .white.opacity(0.5))
                        .fixedSize()
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.memory(item.memMB))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(item.memMB >= 1024 ? 0.9 : 0.62))
                Text("\(ProcessesPage.cpu(item.cpu)) CPU")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(item.cpu >= 25 ? 0.9 : 0.45))
            }
            .fixedSize()
            Button(action: onStop) {
                Group {
                    if stopping {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(hovered ? Color.black.opacity(0.85) : .white.opacity(0.7))
                    }
                }
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovered && !stopping ? Palette.danger.opacity(0.9) : Color.white.opacity(0.09)))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(stopping)
            .accessibilityLabel("Stop \(item.label)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hovered ? 0.08 : 0)))
        .opacity(stopping ? 0.55 : 1)
        .accessibilityElement(children: .contain)
    }
}
