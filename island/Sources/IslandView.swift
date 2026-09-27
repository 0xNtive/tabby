import AppKit
import SwiftUI

enum IslandSpace {
    static let name = "island"
}

struct IslandFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct ViewportKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Root

struct IslandRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: IslandUIState
    let actions: IslandActions

    var body: some View {
        let geometry = ui.geometry
        let onIslandFrame = actions.islandFrame
        let onRowFrames = actions.rowFrames
        let onViewport = actions.viewport
        ZStack(alignment: .top) {
            Color.clear
            island(geometry)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: IslandFrameKey.self,
                                           value: proxy.frame(in: .named(IslandSpace.name)))
                })
        }
        .frame(width: geometry.panelSize.width, height: geometry.panelSize.height, alignment: .top)
        .coordinateSpace(.named(IslandSpace.name))
        .onPreferenceChange(IslandFrameKey.self) { frame in MainActor.assumeIsolated { onIslandFrame(frame) } }
        .onPreferenceChange(RowFramesKey.self) { frames in MainActor.assumeIsolated { onRowFrames(frames) } }
        .onPreferenceChange(ViewportKey.self) { frame in MainActor.assumeIsolated { onViewport(frame) } }
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled()
    }

    // MARK: Island shape

    private func island(_ geometry: IslandGeometry) -> some View {
        let expanded = ui.expanded
        let width = expanded
            ? max(ui.mode.width, collapsedWidth(geometry) + 24)
            : collapsedWidth(geometry)
        let radius: CGFloat = expanded ? 26 : max(8, geometry.barHeight * 0.36)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
                                           bottomTrailingRadius: radius, topTrailingRadius: 0,
                                           style: .continuous)
        return VStack(spacing: 0) {
            header(geometry, expanded: expanded)
                .frame(height: geometry.barHeight)
                .contentShape(Rectangle())
                .onTapGesture { if !ui.expanded { actions.tapHeader() } }
            if expanded {
                expandedBody(geometry)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.04)),
                        removal: .opacity.animation(.easeIn(duration: 0.08))
                    ))
            }
        }
        .frame(width: width, alignment: .top)
        .clipShape(shape)
        .background(
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: expanded ? 22 : 0, x: 0, y: expanded ? 10 : 0)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude sessions")
    }

    private var sessionCount: Int { store.snapshot.sessions.count }

    /// The live activity, while collapsed.
    private var announcement: Announcement? { ui.expanded ? nil : ui.announcement }

    /// Width of each "ear" beside the notch: fits the dots on the left, status on the right.
    private var earWidth: CGFloat {
        let dots = min(sessionCount, 6)
        let dotsWidth = CGFloat(dots) * 12 + CGFloat(max(0, dots - 1)) * 2 + (sessionCount > 6 ? 22 : 0)
        return max(dotsWidth + 20, 46)
    }

    /// An announcement widens both ears (the pill stays centered on the notch) to fit its
    /// message on the right, up to what the panel can hold.
    private func announcementEar(_ announcement: Announcement, _ geometry: IslandGeometry) -> CGFloat {
        let title = min(TextMetrics.width(announcement.title, size: 12, weight: .semibold),
                        announcement.kind == .info ? 320 : 210)
        let suffix = announcement.suffix.map { TextMetrics.width($0, size: 12, weight: .medium) + 4 } ?? 0
        let content = 14 + 6 + title + suffix
        let middle = geometry.hasNotch ? geometry.notchWidth : 12
        let limit = (geometry.panelSize.width - middle) / 2 - 16
        return min(content + 24, limit)
    }

    private func collapsedWidth(_ geometry: IslandGeometry) -> CGFloat {
        let ear = sessionCount == 0 ? (geometry.hasNotch ? 18 : 26) : earWidth
        let right = announcement.map { max(ear, announcementEar($0, geometry)) } ?? ear
        if geometry.hasNotch {
            // Symmetric around the notch. With no sessions the island is just a hair wider
            // than the notch: invisible but hoverable.
            return geometry.notchWidth + 2 * right
        }
        if sessionCount == 0 && announcement == nil { return 64 }
        return ear + right + 12
    }

    // MARK: Header (the part that hugs the notch)

    private func header(_ geometry: IslandGeometry, expanded: Bool) -> some View {
        HStack(spacing: 0) {
            leftEar
            Spacer(minLength: geometry.hasNotch ? geometry.notchWidth + 12 : 12)
            rightEar
        }
        .padding(.horizontal, expanded ? 18 : 10)
    }

    private var leftEar: some View {
        let dots = store.dotSessions
        return HStack(spacing: 2) {
            ForEach(dots.prefix(6)) { session in
                PulseDot(hex: session.dotHex, status: session.status, dotSize: 7, reduceMotion: ui.reduceMotion,
                         celebrates: !ui.expanded)
                    .frame(width: 12, height: 12)
                    .help(session.title)
            }
            if dots.count > 6 {
                Text("+\(dots.count - 6)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 3)
            }
        }
    }

    @ViewBuilder
    private var rightEar: some View {
        let waiting = store.waitingCount
        let busy = store.busyCount
        if let announcement {
            AnnouncementLabel(announcement: announcement)
                .id(announcement.id)
                .transition(ui.reduceMotion
                    ? .opacity
                    : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.86, anchor: .trailing))
                                      .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.08)),
                                  removal: .opacity.animation(.easeIn(duration: 0.12))))
        } else if waiting > 0 {
            HStack(spacing: 4) {
                Bell(count: waiting, reduceMotion: ui.reduceMotion)
                    .frame(width: 12, height: 12)
                Count(value: waiting, color: Palette.waiting, weight: .bold, reduceMotion: ui.reduceMotion)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(waiting) waiting for you")
        } else if busy > 0 {
            HStack(spacing: 4) {
                Spinner(color: NSColor.white.withAlphaComponent(0.8), reduceMotion: ui.reduceMotion)
                    .frame(width: 10, height: 10)
                Count(value: busy, color: .white.opacity(0.85), weight: .semibold, reduceMotion: ui.reduceMotion)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(busy) working")
        } else if sessionCount > 0 {
            Count(value: sessionCount, color: .white.opacity(0.58), weight: .semibold, reduceMotion: ui.reduceMotion)
                .accessibilityLabel("\(sessionCount) idle")
        }
    }

    // MARK: Expanded body

    private func expandedBody(_ geometry: IslandGeometry) -> some View {
        let sessions = store.listSessions
        return VStack(spacing: 0) {
            // The controls sit right under the notch: the island grows downward, so the top
            // never moves while rows open up below or the list changes.
            toolbar(count: sessions.count)
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 18)
            if sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No Claude sessions")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // No frame here: a max-height frame takes the whole proposal and leaves the
                // island tall and half empty. The rows hug their content; only an overflowing
                // list switches to a scroll view (which then fills the rest of the panel).
                ViewThatFits(in: .vertical) {
                    rows(sessions)
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) { rows(sessions) }
                            .mask(ScrollEdgeFade())
                            .onChange(of: ui.hoveredRow) { _, id in
                                guard ui.keyboard, let id else { return }
                                withAnimation(ui.reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                            }
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ViewportKey.self, value: proxy.frame(in: .named(IslandSpace.name)))
                })
            }
            if ui.keyboard || ui.renaming != nil {
                KeyboardHint(renaming: ui.renaming != nil)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            } else {
                // Clear of the rounded bottom corners.
                Color.clear.frame(height: 6)
            }
        }
    }

    private func rows(_ sessions: [IslandSession]) -> some View {
        let detailed = ui.mode == .detailed
        return VStack(spacing: detailed ? 0 : 2) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                if detailed && index > 0 {
                    let quiet = ui.hoveredRow == session.id || ui.hoveredRow == sessions[index - 1].id
                    Rectangle()
                        .fill(Color.white.opacity(quiet ? 0 : 0.07))
                        .frame(height: 1)
                        .padding(.leading, 38)
                        .padding(.trailing, 10)
                }
                SessionRow(session: session,
                           mode: ui.mode,
                           hovered: ui.hoveredRow == session.id,
                           reduceMotion: ui.reduceMotion,
                           renameText: ui.renaming == session.id ? $ui.renameText : nil,
                           onRenameCommit: actions.commitRename,
                           onRenameCancel: actions.cancelRename,
                           onTap: { actions.tapRow(session) },
                           onMenu: { actions.sessionMenu(session) })
                    .modifier(StaggeredEntrance(index: index, enabled: !ui.staticRender, reduceMotion: ui.reduceMotion))
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: RowFramesKey.self,
                                               value: [session.id: proxy.frame(in: .named(IslandSpace.name))])
                    })
                    .id(session.id)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    // MARK: Toolbar

    private func toolbar(count: Int) -> some View {
        HStack(spacing: 8) {
            brand(count: count)
            Spacer(minLength: 8)
            // The theme's name gives way first when a narrow mode is short of room.
            ViewThatFits(in: .horizontal) {
                controls(themeName: true)
                controls(themeName: false)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 18)
    }

    private func brand(count: Int) -> some View {
        HStack(spacing: 6) {
            CatMark(blinks: !ui.reduceMotion && !ui.staticRender)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text("tabby")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
            HStack(spacing: 4) {
                Text("·")
                Text("\(count)")
                    .contentTransition(ui.reduceMotion ? .opacity : .numericText(value: Double(count)))
                    .animation(ui.reduceMotion ? nil : .snappy(duration: 0.35), value: count)
                Text(count == 1 ? "session" : "sessions")
            }
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.58))
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func controls(themeName: Bool) -> some View {
        HStack(spacing: 8) {
            ModePicker(mode: ui.mode, reduceMotion: ui.reduceMotion) { actions.setMode($0) }
            FooterIconButton(symbol: "square.grid.2x2", help: help("Tile session windows", .tile)) { actions.tileMenu() }
            themeButton(showName: themeName)
            FooterIconButton(symbol: "gearshape.fill", help: help("Settings", .settings)) { actions.openSettings() }
        }
        .fixedSize()
    }

    /// "Settings (⌃⌥,)" with the shortcut as configured.
    private func help(_ title: String, _ action: ShortcutAction) -> String {
        let config = store.snapshot.config
        guard config.hotkeys, let combo = config.shortcuts[action] else { return title }
        return "\(title) (\(action.display(combo)))"
    }

    private func themeButton(showName: Bool) -> some View {
        Button {
            actions.themeAllMenu()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 10.5))
                if showName {
                    Text(store.globalThemeName ?? "Theme")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, showName ? 10 : 0)
            .frame(minWidth: 26, minHeight: 26, maxHeight: 26)
            .background(Capsule().fill(Color.white.opacity(0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(showName ? "Theme for every tab" : "Theme for every tab: \(store.globalThemeName ?? "tabby")")
        .accessibilityLabel("Theme for every tab")
    }
}

// MARK: - Collapsed pieces

/// A count that rolls its digits when it changes.
struct Count: View {
    let value: Int
    let color: Color
    let weight: Font.Weight
    let reduceMotion: Bool

    var body: some View {
        Text("\(value)")
            .font(.system(size: 11, weight: weight).monospacedDigit())
            .foregroundStyle(color)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(value)))
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: value)
    }
}

/// "✓ Title is done" / "🔔 Title needs you" on the right ear.
struct AnnouncementLabel: View {
    let announcement: Announcement

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: announcement.symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(announcement.tint)
                .frame(width: 14)
            HStack(spacing: 4) {
                Text(announcement.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let suffix = announcement.suffix {
                    Text(suffix)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(announcement.tint)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .help(announcement.detail ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Toolbar pieces

/// Minimal · Standard · Detailed as three icons; the selection slides between them.
struct ModePicker: View {
    let mode: IslandMode
    let reduceMotion: Bool
    let onSelect: (IslandMode) -> Void
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(IslandMode.allCases) { option in
                Button {
                    onSelect(option)
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(option == mode ? 0.95 : 0.5))
                        .frame(width: 26, height: 22)
                        .background {
                            if option == mode {
                                Capsule()
                                    .fill(Color.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(option.help)
                .accessibilityLabel("\(option.title) mode")
                .accessibilityAddTraits(option == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: mode)
    }
}

struct FooterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shown while the island has keyboard focus (⌃⌥Space); drops labels to fit narrow modes.
struct KeyboardHint: View {
    private typealias Item = (key: String, label: String)
    private let full: [Item] = [
        ("↑↓", "select"), ("↩", "open"), ("R", "rename"), ("C", "color"),
        ("T", "theme"), ("M", "mode"), ("G", "tile"), ("W", "watermark"), ("esc", "close"),
    ]
    private let short: [Item] = [
        ("↑↓", ""), ("↩", "open"), ("R", "rename"), ("C", "color"),
        ("T", "theme"), ("M", "mode"), ("G", "tile"), ("esc", ""),
    ]
    private let keys: [Item] = [
        ("↑↓", ""), ("↩", ""), ("R", "rename"), ("C", "color"), ("T", "theme"), ("M", "mode"), ("G", "tile"), ("esc", ""),
    ]
    private let rename: [Item] = [("↩", "save"), ("esc", "cancel")]
    var renaming = false

    var body: some View {
        Group {
            if renaming {
                HStack(spacing: 10) {
                    row(rename, spacing: 10)
                    Text("Leave it empty to let AI name it")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    row(full, spacing: 9)
                    row(short, spacing: 8)
                    row(keys, spacing: 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(renaming
            ? "Return saves the name, Escape cancels. Leave it empty to let AI name it."
            : "Keyboard: arrows select, Return opens, R rename, C color, T theme, M mode, G tile, W watermark, comma settings, Escape closes")
    }

    private func row(_ items: [Item], spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(items, id: \.key) { item in
                HStack(spacing: 4) {
                    Text(item.key)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.13)))
                    if !item.label.isEmpty {
                        Text(item.label)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Fades a scrolling list into the island's black at both ends.
struct ScrollEdgeFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 8)
            Rectangle().fill(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
        }
    }
}
