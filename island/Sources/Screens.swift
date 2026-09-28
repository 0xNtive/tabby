import AppKit
import SwiftUI

// MARK: - Screen map

/// The displays as they're arranged, drawn to scale (like System Settings › Displays), each with
/// a tick when Claude sessions go there. Click one to add or remove it.
struct ScreenMap: View {
    let screens: [ScreenInfo]
    let used: Set<String>
    let focused: String?
    var height: CGFloat = 180
    let toggle: (ScreenInfo) -> Void

    var body: some View {
        GeometryReader { proxy in
            let union = screens.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = union.isNull ? 1 : min((proxy.size.width - 8) / union.width, (proxy.size.height - 8) / union.height)
            let offset = CGPoint(x: (proxy.size.width - union.width * scale) / 2, y: (proxy.size.height - union.height * scale) / 2)
            ZStack(alignment: .topLeading) {
                ForEach(Array(screens.enumerated()), id: \.element.key) { index, screen in
                    let rect = CGRect(x: offset.x + (screen.frame.minX - union.minX) * scale,
                                      y: offset.y + (union.maxY - screen.frame.maxY) * scale,
                                      width: screen.frame.width * scale, height: screen.frame.height * scale)
                    ScreenTile(screen: screen, number: index + 1, used: used.contains(screen.key),
                               focused: screen.key == focused, size: rect.size) { toggle(screen) }
                        .offset(x: rect.minX + 2, y: rect.minY + 2)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screens")
    }
}

private struct ScreenTile: View {
    let screen: ScreenInfo
    let number: Int
    let used: Bool
    let focused: Bool
    let size: CGSize
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let w = max(size.width - 4, 10)
        let h = max(size.height - 4, 10)
        Button(action: action) {
            ZStack(alignment: .top) {
                shape.fill(used ? Color.accentColor.opacity(0.2) : Color.primary.opacity(hovered ? 0.09 : 0.045))
                shape.strokeBorder(used ? Color.accentColor : Color.primary.opacity(0.22), lineWidth: used ? 1.5 : 1)
                // The menu bar, and the camera notch.
                if screen.isPrimary || screen.hasNotch {
                    UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.16))
                        .frame(height: max(3, min(6, h * 0.06)))
                }
                if screen.hasNotch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: w * 0.14, height: max(3, min(6, h * 0.06)))
                }
                VStack(spacing: 1) {
                    Text(screen.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                    if h > 64 {
                        Text(screen.sizeText)
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if screen.isPrimary && h > 84 {
                        Text("main screen")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: used ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(used ? Color.accentColor : Color.secondary.opacity(0.6))
                }
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 5)
            }
            .frame(width: w, height: h)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(used ? "Claude sessions go on \(screen.name). Click to keep it free." : "Click to put Claude sessions on \(screen.name).")
        .accessibilityLabel("\(screen.name), \(screen.sizeText)\(focused ? ", the screen you're on" : "")")
        .accessibilityValue(used ? "used for Claude sessions" : "kept free")
        .accessibilityAddTraits(used ? .isSelected : [])
    }
}

// MARK: - Settings › Windows

/// Where sessions go (screens), what tiling tiles, and quick launch.
struct WindowsPane: View {
    let island: IslandController
    @ObservedObject var state: SettingsState
    @State private var screens: [ScreenInfo] = ScreenInfo.current()
    @State private var focused: String?

    private var config: IslandConfig { state.config }

    var body: some View {
        Form {
            Section {
                Picker("Put sessions on", selection: Binding(get: { config.tileScreens.kind }, set: setKind)) {
                    ForEach(TileScreens.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ScreenMap(screens: screens, used: config.tileScreens.used(screens, focused: focused), focused: focused) { screen in
                    island.setSetting("tileScreens", config.tileScreens.toggling(screen.key, screens: screens, focused: focused).config)
                }
                .padding(.vertical, 4)
                if case .chosen(let keys) = config.tileScreens, !Set(keys).isSubset(of: screens.map(\.key)) {
                    Label("A screen you picked isn't connected right now: it's skipped until it's back.",
                          systemImage: "display.trianglebadge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Screens for Claude sessions")
            } footer: {
                Text("Tiling and new sessions use these, so you can keep a screen free: tick only the vertical monitor, say, and your main screen stays yours. Click a screen to add or remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Tile", selection: Binding(get: { config.tileScope }, set: { island.setSetting("tileScope", .string($0.rawValue)) })) {
                    ForEach(TileScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Tiling")
            } footer: {
                Text("\(ShortcutAction.tile.display(config.shortcuts[.tile])) and the tile button follow this. The tile menu can also pick sessions one by one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Start a session in a recent folder")
                    Spacer()
                    Text(ShortcutAction.launch.display(config.shortcuts[.launch]))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                    Button("Open") { island.showQuickLaunch() }
                }
                Toggle(isOn: Binding(get: { config.launchSkipPermissions }, set: { island.setSetting("launchSkipPermissions", .bool($0)) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start with “Skip permissions” ticked")
                        Text("Adds --dangerously-skip-permissions: Claude runs every tool without asking first. Only for folders you trust; you can untick it in the launcher each time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Quick launch")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in reload() }
    }

    private func reload() {
        screens = ScreenInfo.current()
        focused = ScreenInfo.focusedKey(in: screens)
    }

    /// The segmented control: "Screens I pick" starts from the screens in use now.
    private func setKind(_ kind: TileScreens.Kind) {
        switch kind {
        case .current: island.setSetting("tileScreens", TileScreens.current.config)
        case .all: island.setSetting("tileScreens", TileScreens.all.config)
        case .chosen:
            guard config.tileScreens.kind != .chosen else { return }
            let used = config.tileScreens.used(screens, focused: focused)
            island.setSetting("tileScreens", TileScreens.chosen(screens.map(\.key).filter(used.contains)).config)
        }
    }
}
