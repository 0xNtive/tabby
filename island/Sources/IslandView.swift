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
    }

    // MARK: Island shape

    private func island(_ geometry: IslandGeometry) -> some View {
        let expanded = ui.expanded
        let width = expanded
            ? max(IslandGeometry.expandedWidth, collapsedWidth(geometry) + 24)
            : collapsedWidth(geometry)
        let radius: CGFloat = expanded ? 26 : max(8, geometry.barHeight * 0.36)
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius,
                                           bottomTrailingRadius: radius, topTrailingRadius: 0,
                                           style: .continuous)
        return VStack(spacing: 0) {
            header(geometry, expanded: expanded)
                .frame(height: geometry.barHeight)
                .contentShape(Rectangle())
                .onTapGesture { if !ui.expanded { actions.expand() } }
            if expanded {
                expandedBody(geometry)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.06)),
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

    /// Width of each "ear" beside the notch: fits the dots on the left, status on the right.
    private var earWidth: CGFloat {
        let dots = min(sessionCount, 6)
        let dotsWidth = CGFloat(dots) * 12 + CGFloat(max(0, dots - 1)) * 2 + (sessionCount > 6 ? 22 : 0)
        return max(dotsWidth + 20, 46)
    }

    private func collapsedWidth(_ geometry: IslandGeometry) -> CGFloat {
        if geometry.hasNotch {
            // With no sessions the island is just a hair wider than the notch: invisible but hoverable.
            return geometry.notchWidth + 2 * (sessionCount == 0 ? 18 : earWidth)
        }
        return sessionCount == 0 ? 64 : 2 * earWidth + 12
    }

    // MARK: Header (the part that hugs the notch)

    private func header(_ geometry: IslandGeometry, expanded: Bool) -> some View {
        HStack(spacing: 0) {
            leftEar
            Spacer(minLength: geometry.hasNotch ? geometry.notchWidth : 12)
            rightEar
        }
        .padding(.horizontal, expanded ? 18 : 10)
    }

    private var leftEar: some View {
        let dots = store.dotSessions
        return HStack(spacing: 2) {
            ForEach(dots.prefix(6)) { session in
                PulseDot(hex: session.accentHex, status: session.status, dotSize: 7, reduceMotion: ui.reduceMotion)
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
        if waiting > 0 {
            HStack(spacing: 3) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(waiting)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(Palette.waiting)
            .accessibilityLabel("\(waiting) waiting for you")
        } else if busy > 0 {
            HStack(spacing: 4) {
                Spinner(color: NSColor.white.withAlphaComponent(0.8), reduceMotion: ui.reduceMotion)
                    .frame(width: 10, height: 10)
                Text("\(busy)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .accessibilityLabel("\(busy) working")
        } else if sessionCount > 0 {
            Text("\(sessionCount)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .accessibilityLabel("\(sessionCount) idle")
        }
    }

    // MARK: Expanded body

    private func expandedBody(_ geometry: IslandGeometry) -> some View {
        let sessions = store.listSessions
        return VStack(spacing: 0) {
            if sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("No Claude sessions")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                // No frame here: a max-height frame takes the whole proposal and leaves the
                // island tall and half empty. The rows hug their content; only an overflowing
                // list switches to a scroll view (which then fills the rest of the panel).
                ViewThatFits(in: .vertical) {
                    rows(sessions)
                    ScrollView(.vertical, showsIndicators: false) { rows(sessions) }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ViewportKey.self, value: proxy.frame(in: .named(IslandSpace.name)))
                })
            }
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 16)
            footer(count: sessions.count)
        }
    }

    private func rows(_ sessions: [IslandSession]) -> some View {
        VStack(spacing: 2) {
            ForEach(sessions) { session in
                SessionRow(session: session,
                           hovered: ui.hoveredRow == session.id,
                           reduceMotion: ui.reduceMotion,
                           onTap: { actions.tapRow(session) },
                           onMenu: { actions.sessionMenu(session) })
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: RowFramesKey.self,
                                               value: [session.id: proxy.frame(in: .named(IslandSpace.name))])
                    })
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func footer(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(count) session\(count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Button {
                actions.themeAllMenu()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 10.5))
                    Text(store.globalThemeName.map { "Theme · \($0)" } ?? "Theme")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Apply a theme to every tab")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: IslandSession
    let hovered: Bool
    let reduceMotion: Bool
    let onTap: () -> Void
    let onMenu: () -> Void

    private var accent: Color { Color(hexString: session.accentHex) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PulseDot(hex: session.accentHex, status: session.status, dotSize: 9, reduceMotion: reduceMotion)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if hovered {
                        Button(action: onMenu) {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Rename, color, theme…")
                        .transition(.opacity)
                    }
                }
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(secondaryLine(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                ContextBar(pct: session.contextPct, accent: accent)
                    .padding(.top, 1)
                if hovered {
                    details
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.075 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onTap)
        .overlay(RightClickCatcher { _ in onMenu() })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.project), \(session.statusDetail)")
        .accessibilityAddTraits(.isButton)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let summary = session.summary {
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = session.note {
                Label(note, systemImage: "note.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let prompt = session.lastPrompt {
                Text("“\(prompt)”")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 5) {
                Image(systemName: session.status.symbol)
                Text(statusLine)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(statusColor)
            .lineLimit(1)
        }
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: String {
        var parts = [session.statusDetail]
        if let used = session.context?.usedTokens {
            if let window = session.context?.windowSize {
                parts.append("\(Fmt.tokens(used)) / \(Fmt.tokens(window)) tokens")
            } else {
                parts.append("\(Fmt.tokens(used)) tokens")
            }
        }
        if let cost = session.context?.costUsd, cost > 0 { parts.append(Fmt.cost(cost)) }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch session.status {
        case .waiting: return Palette.waiting
        case .error: return Palette.danger
        default: return Color.white.opacity(0.55)
        }
    }

    private func secondaryLine(now: Date) -> String {
        [session.project, session.model, Fmt.ago(session.activityAt, now: now)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

// MARK: - Context bar

struct ContextBar: View {
    let pct: Double?
    let accent: Color

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
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(pct == nil ? 0.3 : 0.62))
                .frame(width: 32, alignment: .trailing)
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel(pct.map { "Context \(Int($0.rounded())) percent used" } ?? "Context usage unknown")
    }

    private func color(for pct: Double) -> Color {
        if pct >= 90 { return Palette.danger }
        if pct >= 70 { return Palette.warn }
        return accent
    }
}
