import AppKit
import Carbon.HIToolbox
import SwiftUI

// Tile some sessions instead of all of them: "Tile Active Sessions" and "Choose Sessions…" in the
// tile menu, the picker itself, and how the island reaches its controller for them.

extension IslandController {
    /// The app's island (menus built by MenuFactory reach it through this).
    @MainActor static weak var current: IslandController?

    /// `tabby tile --active`: only sessions working or waiting on you.
    func tileActive() { tile(nil, extra: ["--active"]) }

    /// These sessions only, wherever they are in the list.
    func tile(sessions: [IslandSession]) {
        guard !sessions.isEmpty else { return }
        tile(nil, extra: ["--only", sessions.map(\.tileToken).joined(separator: ",")])
    }

    func showTilePicker() {
        setExpanded(false)
        TilePickerController.shared.show(island: self)
    }

    func showQuickLaunch() {
        setExpanded(false)
        QuickLaunchController.shared.toggle(island: self)
    }
}

extension Actions {
    /// `tabby tile [n] [flags]`.
    static func tile(_ count: Int?, extra: [String], completion: @escaping @MainActor (String) -> Void) {
        runCLI(["tile"] + (count.map { [String($0)] } ?? []) + extra) { _, output in completion(output) }
    }
}

extension MenuFactory {
    /// "Tile Active Sessions (n)" and "Choose Sessions…", for the tile menu.
    func tileSelectionItems(sessions: [IslandSession]) -> [NSMenuItem] {
        let tileable = sessions.filter(\.isTileable)
        let active = tileable.filter(\.isActive).count
        let activeItem = item("Tile Active Sessions (\(active))", symbol: "bolt.horizontal") {
            IslandController.current?.tileActive()
        }
        activeItem.toolTip = "Only sessions that are working or waiting on you"
        activeItem.isEnabled = active > 0
        let choose = item("Choose Sessions…", symbol: "checklist") { IslandController.current?.showTilePicker() }
        choose.isEnabled = !tileable.isEmpty
        return [activeItem, choose]
    }
}

// MARK: - Picker

@MainActor
final class TilePickerModel: ObservableObject {
    @Published var sessions: [IslandSession] = []
    @Published var selected: Set<String> = []
    @Published var screensText = ""

    var tileable: [IslandSession] { sessions.filter(\.isTileable) }
    var chosen: [IslandSession] { tileable.filter { selected.contains($0.id) } }

    func toggle(_ session: IslandSession) {
        guard session.isTileable else { return }
        if selected.contains(session.id) { selected.remove(session.id) } else { selected.insert(session.id) }
    }

    func selectActive() { selected = Set(tileable.filter(\.isActive).map(\.id)) }
    func selectAll() { selected = Set(tileable.map(\.id)) }
    func selectNone() { selected = [] }
}

@MainActor
final class TilePickerController: NSObject, NSWindowDelegate {
    static let shared = TilePickerController()

    let model = TilePickerModel()
    private weak var island: IslandController?
    private lazy var panel: FloatingKeyPanel = {
        let panel = FloatingKeyPanel(size: CGSize(width: 420, height: 420))
        panel.contentView = NSHostingView(rootView: TilePickerView(model: model, tile: { [weak self] in self?.tile() },
                                                                   cancel: { [weak self] in self?.close() }))
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        return panel
    }()

    func show(island: IslandController) {
        self.island = island
        model.sessions = island.store.snapshot.sessions
        // Last time's choice while those sessions still run; else the active ones.
        let still = model.selected.intersection(model.tileable.map(\.id))
        if still.isEmpty { model.selectActive() } else { model.selected = still }
        if model.selected.isEmpty { model.selectAll() }
        model.screensText = Self.screensText(island.config.tileScreens)
        panel.present(size: Self.size(for: model.sessions.count))
    }

    static func size(for count: Int) -> CGSize {
        CGSize(width: 420, height: min(560, 178 + CGFloat(max(count, 1)) * 44))
    }

    static func screensText(_ pref: TileScreens) -> String {
        let screens = ScreenInfo.current()
        let used = pref.used(screens, focused: ScreenInfo.focusedKey(in: screens))
        let names = screens.filter { used.contains($0.key) }.map(\.name)
        switch pref {
        case .current: return "the screen you're on"
        case .all where screens.count > 1: return "all \(screens.count) screens"
        default: return names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    func close() { panel.orderOut(nil) }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func tile() {
        let chosen = model.chosen
        close()
        island?.tile(sessions: chosen)
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !model.chosen.isEmpty { tile() }
            return true
        case kVK_ANSI_A where event.modifierFlags.contains(.command):
            model.selectAll()
            return true
        default:
            return false
        }
    }
}

struct TilePickerView: View {
    @ObservedObject var model: TilePickerModel
    let tile: () -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        IslandCard {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tile which sessions?")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Each becomes its own window on \(model.screensText). The rest stay where they are.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                HStack(spacing: 6) {
                    chip("Active", count: model.tileable.filter(\.isActive).count, action: model.selectActive)
                    chip("All", count: model.tileable.count, action: model.selectAll)
                    chip("None", count: nil, action: model.selectNone)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.sessions) { session in
                            PickerRow(session: session, checked: model.selected.contains(session.id), reduceMotion: reduceMotion)
                                .onTapGesture { model.toggle(session) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 10) {
                    Text("↩ tile · esc cancel")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    Button("Cancel", action: cancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                    Button(model.chosen.count == 1 ? "Tile 1 Session" : "Tile \(model.chosen.count) Sessions", action: tile)
                        .buttonStyle(MarmaladeButtonStyle(compact: true))
                        .disabled(model.chosen.isEmpty)
                        .opacity(model.chosen.isEmpty ? 0.45 : 1)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.03))
            }
        }
    }

    private func chip(_ title: String, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let count { Text("\(count)").foregroundStyle(.white.opacity(0.45)) }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PickerRow: View {
    let session: IslandSession
    let checked: Bool
    let reduceMotion: Bool
    @State private var hovered = false

    var body: some View {
        let enabled = session.isTileable
        HStack(spacing: 10) {
            Image(systemName: checked && enabled ? "checkmark.square.fill" : "square")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(checked && enabled ? Color(nsColor: Brand.marmalade) : .white.opacity(0.35))
            PulseDot(hex: session.dotHex, status: session.status, dotSize: 8, reduceMotion: reduceMotion)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text(enabled ? session.project : "\(session.project) · not in Terminal or iTerm2")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusLabel(session: session, now: Date(), chip: false)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovered && enabled ? 0.07 : 0)))
        .opacity(enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.project), \(session.statusDetail)")
        .accessibilityValue(checked ? "selected" : "not selected")
        .accessibilityAddTraits(.isButton)
    }
}
