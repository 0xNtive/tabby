import AppKit
import Darwin
import SwiftUI

// MARK: - State (from the tabby CLI's awake.json)

/// Awake: the Mac keeps running with the lid closed until a time, or until every session is
/// done. `tabby awake` writes <Claude folder>/tabby/awake.json; a watcher it starts turns sleep
/// back on. The island only reads the file and runs the CLI.
struct AwakeState: Equatable, Sendable {
    var on: Bool
    var token: String
    var startedAt: Date
    var until: Date
    var untilDone: Bool
    var minBattery: Int
    var watcherPid: Int32?
    var endedAt: Date?
    /// time, done, battery, off, external
    var reason: String?
    /// Sessions that worked while it was on (set when it ends).
    var worked: Int?
    /// False when tabby couldn't turn sleep back on.
    var restored: Bool

    static var file: URL { ClaudePaths.tabby.appendingPathComponent("awake.json") }

    static func read() -> AwakeState? {
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func date(_ key: String) -> Date? {
            (json[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        guard let startedAt = date("startedAt"), let until = date("until") else { return nil }
        return AwakeState(on: (json["on"] as? Bool) ?? false,
                          token: (json["token"] as? String) ?? "",
                          startedAt: startedAt, until: until,
                          untilDone: (json["untilDone"] as? Bool) ?? false,
                          minBattery: (json["minBattery"] as? NSNumber)?.intValue ?? 10,
                          watcherPid: (json["watcherPid"] as? NSNumber)?.int32Value,
                          endedAt: date("endedAt"),
                          reason: json["reason"] as? String,
                          worked: (json["worked"] as? NSNumber)?.intValue,
                          restored: (json["restored"] as? Bool) ?? true)
    }

    func left(now: Date) -> TimeInterval { max(0, until.timeIntervalSince(now)) }

    /// How much of the time is left, 1…0 (the ring empties as it runs).
    func fraction(now: Date) -> Double {
        let total = until.timeIntervalSince(startedAt)
        guard total > 0 else { return 0 }
        return min(1, max(0, left(now: now) / total))
    }

    /// On, but nobody is keeping time: the watcher is gone (a restart) or the end was missed.
    func needsCheck(now: Date) -> Bool {
        guard on else { return false }
        if now > until.addingTimeInterval(30) { return true }
        guard let pid = watcherPid, pid > 0 else { return true }
        return !(kill(pid, 0) == 0 || errno == EPERM)
    }

    /// "every session is done", "time's up"…
    var reasonText: String {
        switch reason {
        case "done": return "every session is done"
        case "time": return "time's up"
        case "battery": return "battery low"
        case "external": return "sleep was turned on elsewhere"
        default: return "turned off"
        }
    }

    /// Snapshot renders for the website show US times ("3:40 AM") whatever this Mac uses, at a
    /// fixed moment of a night (so the times in a render agree with each other).
    static var locale: Locale?
    static var fixedNow: Date?
    static var now: Date { fixedNow ?? Date() }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        if let locale { formatter.locale = locale }
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// "3h 12m", "40m"
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// What `tabby awake --json` adds: whether the permission is in place, and the battery.
struct AwakeInfo: Decodable, Equatable, Sendable {
    struct Battery: Decodable, Equatable, Sendable {
        var present: Bool
        var ac: Bool
        var pct: Int?
    }

    var allowed: Bool
    var battery: Battery?

    static func parse(_ output: String) -> AwakeInfo? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        return try? JSONDecoder().decode(AwakeInfo.self, from: Data(output[start...].utf8))
    }
}

// MARK: - Model (actions through the CLI)

@MainActor
final class AwakeModel: ObservableObject {
    static let shared = AwakeModel()

    /// The CLI is starting or stopping it (the first start waits on the macOS password prompt).
    @Published var busy: String?
    @Published var info: AwakeInfo?
    /// What the last action said, for a few seconds.
    @Published var notice: (text: String, ok: Bool)? {
        didSet { noticeWork?.cancel() }
    }
    /// Sleep as soon as every session is done (the chips are then the most it may take).
    @Published var untilDone: Bool = UserDefaults.standard.object(forKey: "awakeUntilDone") as? Bool ?? true {
        didSet { UserDefaults.standard.set(untilDone, forKey: "awakeUntilDone") }
    }

    private var noticeWork: DispatchWorkItem?
    private var infoAt = Date.distantPast
    private var checkAt = Date.distantPast
    var fixed = false

    static let choices: [(label: String, hours: Int)] = [("1h", 1), ("2h", 2), ("4h", 4), ("8h", 8)]

    /// Whether the permission is in place and what the battery says (when the page opens).
    func loadInfo(force: Bool = false) {
        guard !fixed, force || Date().timeIntervalSince(infoAt) > 20 else { return }
        infoAt = Date()
        Actions.runCLI(["awake", "--json"]) { [weak self] _, output in
            if let info = AwakeInfo.parse(output) { self?.info = info }
        }
    }

    /// `untilDone`: this once, whatever the page's checkbox says (the status menu).
    func start(hours: Int, untilDone: Bool? = nil) {
        var args = ["awake", "\(hours)h"]
        if untilDone ?? self.untilDone { args.append("--until-done") }
        run(args, busy: info?.allowed == false ? "Allow it in the macOS prompt…" : "Starting…")
    }

    func extend(hours: Int = 1) { run(["awake", "+\(hours)h"], busy: "Adding time…") }

    func stop() { run(["awake", "off"], busy: "Stopping…") }

    private func run(_ args: [String], busy text: String) {
        guard !fixed, busy == nil else { return }
        busy = text
        Actions.runCLI(args) { [weak self] status, output in
            guard let self else { return }
            self.busy = nil
            let line = output.split(separator: "\n").first.map(String.init) ?? ""
            if status != 0 { self.say(line.isEmpty ? "Could not change it" : line, ok: false) }
            self.loadInfo(force: true)
        }
    }

    /// Puts things right when the watcher is gone (a restart) or the end was missed.
    func checkIfNeeded(_ state: AwakeState?) {
        guard !fixed, let state, state.needsCheck(now: Date()), Date().timeIntervalSince(checkAt) > 60 else { return }
        checkAt = Date()
        Debug.log("awake: checking (watcher gone or time passed)")
        Actions.runCLI(["awake", "_check"])
    }

    func say(_ text: String, ok: Bool) {
        notice = (text, ok)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.notice = nil }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

extension Announcement {
    /// "Awake for 4h" · "Close the lid any time. Claude keeps working."
    static func awakeOn(_ state: AwakeState) -> Announcement {
        let span = AwakeState.span(state.left(now: AwakeState.now))
        var announcement = Announcement(kind: .info, title: "Awake for \(span)",
                                        suffix: state.untilDone ? "or until done" : nil, symbol: "cup.and.saucer.fill",
                                        sessionId: nil, topic: "awake")
        announcement.subtitle = "Close the lid any time. Claude keeps working."
        announcement.accent = Color(nsColor: Brand.marmalade)
        return announcement
    }

    /// "Sleep is back on" · "Every session is done · 4 worked meanwhile".
    static func awakeOff(_ state: AwakeState) -> Announcement {
        let failed = !state.restored
        var announcement = Announcement(kind: .info, title: failed ? "Sleep is still off" : "Sleep is back on",
                                        suffix: nil, symbol: failed ? "exclamationmark.triangle.fill" : "moon.fill",
                                        sessionId: nil, topic: "awake")
        var parts = [state.reasonText.prefix(1).uppercased() + state.reasonText.dropFirst()]
        if let worked = state.worked, worked > 0 { parts.append("\(worked) session\(worked == 1 ? "" : "s") worked") }
        if let ended = state.endedAt { parts.append("at \(AwakeState.clock(ended))") }
        announcement.subtitle = failed ? "tabby couldn't turn it back on: run tabby awake off" : parts.joined(separator: " · ")
        return announcement
    }
}

// MARK: - Page

struct AwakePage: View {
    @ObservedObject var model: AwakeModel
    let state: AwakeState?
    let hovered: String?
    let reduceMotion: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .awake, subtitle: "Keep running with the lid closed", loading: model.busy != nil,
                       onBack: onBack, onRefresh: nil)
            if let notice = model.notice {
                PageNotice(text: notice.text, ok: notice.ok)
            }
            Group {
                if let state, state.on {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        running(state, now: AwakeState.fixedNow ?? context.date)
                    }
                } else {
                    choose
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .onAppear { model.loadInfo() }
    }

    // MARK: On

    private func running(_ state: AwakeState, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    ProgressRing(fraction: state.fraction(now: now), color: Brand.marmalade, lineWidth: 3.5,
                                 reduceMotion: reduceMotion)
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Brand.marmalade))
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(AwakeState.span(state.left(now: now))) left")
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.96))
                        .contentTransition(.numericText())
                    Text(state.untilDone
                         ? "Until every session is done · \(AwakeState.clock(state.until)) at the latest"
                         : "Until \(AwakeState.clock(state.until))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                VStack(spacing: 6) {
                    chip("+1h", id: "a:more", filled: false) { model.extend() }
                    chip("Stop", id: "a:stop", filled: false, tint: .white) { model.stop() }
                }
                .fixedSize()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: Brand.marmalade).opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: Brand.marmalade).opacity(0.28)))
            footnote(symbol: "laptopcomputer", "Close the lid any time. Claude keeps working.", strong: true)
            footnote(symbol: "moon.fill", "Sleep comes back on by itself\(state.untilDone ? " when the work is done" : ""), or below \(state.minBattery)% battery.\(batteryNote)")
        }
    }

    // MARK: Off

    private var choose: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.untilDone ? "AT MOST" : "FOR")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 2)
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            } else {
                HStack(spacing: 6) {
                    ForEach(AwakeModel.choices, id: \.hours) { choice in
                        chip(choice.label, id: "a:\(choice.hours)", filled: true, wide: true) { model.start(hours: choice.hours) }
                    }
                }
            }
            Button {
                model.untilDone.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.untilDone ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(model.untilDone ? Color(nsColor: Brand.marmalade) : .white.opacity(0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sleep as soon as every session is done")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                        Text("Nothing working for 5 minutes counts as done")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(hovered == "a:done" ? 0.08 : 0.04)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pageRow("a:done")
            .accessibilityLabel("Sleep as soon as every session is done")
            .accessibilityAddTraits(model.untilDone ? .isSelected : [])
            footnote(symbol: "laptopcomputer", "Then close the lid. Claude keeps working.", strong: true)
            footnote(symbol: "moon.fill", "Sleep comes back on by itself, or below 10% battery.\(batteryNote)")
            if model.info?.allowed == false {
                footnote(symbol: "lock.fill", "The first time, macOS asks for your password: tabby may then turn sleep off and on, nothing else.")
            }
            if let state, !state.on, let ended = state.endedAt, Date().timeIntervalSince(ended) < 12 * 3600 {
                footnote(symbol: "clock", "Last time: ended at \(AwakeState.clock(ended)), \(state.reasonText)\(state.worked.map { $0 > 0 ? ", \($0) session\($0 == 1 ? "" : "s") worked" : "" } ?? "").")
            }
        }
    }

    private var batteryNote: String {
        guard let battery = model.info?.battery, battery.present, let pct = battery.pct else { return "" }
        return battery.ac ? " Plugged in (\(pct)%)." : " On battery: \(pct)%."
    }

    // MARK: Pieces

    private func chip(_ title: String, id: String, filled: Bool, wide: Bool = false, tint: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        let lit = hovered == id
        let accent = Color(nsColor: Brand.marmalade)
        return Button(action: action) {
            Text(title)
                .font(.system(size: wide ? 13 : 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(filled ? (lit ? Color.black.opacity(0.9) : accent) : (tint ?? accent).opacity(0.92))
                .frame(maxWidth: wide ? .infinity : nil)
                .padding(.horizontal, wide ? 0 : 12)
                .frame(height: wide ? 34 : 24)
                .background(
                    RoundedRectangle(cornerRadius: wide ? 10 : 12, style: .continuous)
                        .fill(filled ? (lit ? accent : accent.opacity(0.13)) : Color.white.opacity(lit ? 0.16 : 0.09))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pageRow(id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: lit)
        .accessibilityLabel(wide ? "Keep awake for \(title)" : title)
    }

    private func footnote(symbol: String, _ text: String, strong: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(strong ? 0.7 : 0.4))
                .frame(width: 14)
            Text(text)
                .font(.system(size: strong ? 11.5 : 10.5, weight: strong ? .medium : .regular))
                .foregroundStyle(.white.opacity(strong ? 0.82 : 0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 2)
    }
}

/// The small cup beside the dots while Awake is on.
struct AwakeCup: View {
    var body: some View {
        Image(systemName: "cup.and.saucer.fill")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(Color(nsColor: Brand.marmalade))
            .frame(width: 14, height: 12)
            .accessibilityLabel("Awake: the Mac keeps running with the lid closed")
    }
}
