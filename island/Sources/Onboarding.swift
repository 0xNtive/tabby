import AppKit
import SwiftUI

// MARK: - Model

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome, permissions, done
    var id: Int { rawValue }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var page: OnboardingPage = .welcome
    /// Which way the last page change went, for the slide.
    @Published var forward = true

    func go(_ next: OnboardingPage, reduceMotion: Bool) {
        forward = next.rawValue >= page.rawValue
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.46, dampingFraction: 0.88)) {
            page = next
        }
    }
}

/// The brand, for the onboarding's own look (the rest of the island follows the system).
enum OnboardingStyle {
    static let harbor = Color(nsColor: Brand.harbor)
    static let harborDeep = Color(hexString: "#0a2b2d")
    static let foam = Color(nsColor: Brand.foam)
    static let foamSoft = Color(hexString: "#b9ccc6")
    static let marmalade = Color(nsColor: Brand.marmalade)
    static let moss = Color(hexString: "#a7d98f")
    static let warning = Color(hexString: "#f6b26b")
}

// MARK: - Window

/// A first-run window, like installing a Mac app: welcome, the permissions (checked live), and
/// the shortcuts to start with. Shown once on first launch, by the installer
/// (`tabby island onboarding`), and from the status menu.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model = OnboardingModel()
    private let window: NSWindow
    private let permissions: PermissionCenter
    private var watching = false
    var onClose: (() -> Void)?

    init(island: IslandController, permissions: PermissionCenter, state: SettingsState) {
        self.permissions = permissions
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to tabby"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Brand.harbor
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(
            model: model, permissions: permissions, state: state, island: island,
            finish: { [weak self] in self?.window.performClose(nil) }))
        window.center()
        window.delegate = self
    }

    var isVisible: Bool { window.isVisible }

    /// `activate`: brought to the front with keyboard focus (the installer, the menu). Otherwise
    /// it appears without taking focus from what you're typing in; click it to continue.
    func show(page: OnboardingPage, activate: Bool) {
        model.page = page
        if !watching {
            watching = true
            permissions.startWatching()
        }
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if watching {
            watching = false
            permissions.stopWatching()
        }
        onClose?()
    }
}

// MARK: - Root

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var state: SettingsState
    let island: IslandController
    let finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [OnboardingStyle.harbor, OnboardingStyle.harborDeep], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [OnboardingStyle.marmalade.opacity(0.16), .clear], center: .init(x: 0.5, y: 0.08),
                           startRadius: 0, endRadius: 360)
                .opacity(model.page == .welcome ? 1 : 0.45)
            VStack(spacing: 0) {
                ZStack {
                    switch model.page {
                    case .welcome: WelcomePage().transition(slide)
                    case .permissions: PermissionsPage(permissions: permissions, state: state, island: island).transition(slide)
                    case .done: DonePage(permissions: permissions, config: state.config).transition(slide)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 34)
                footer
            }
        }
        .frame(width: 720, height: 560)
        .foregroundStyle(OnboardingStyle.foam)
        .environment(\.colorScheme, .dark)
    }

    private var slide: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset: CGFloat = model.forward ? 44 : -44
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: offset)),
                           removal: .opacity.combined(with: .offset(x: -offset)))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(OnboardingPage.allCases) { page in
                    Capsule()
                        .fill(page == model.page ? OnboardingStyle.marmalade : OnboardingStyle.foam.opacity(0.22))
                        .frame(width: page == model.page ? 20 : 7, height: 7)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: model.page)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(model.page.rawValue + 1) of \(OnboardingPage.allCases.count)")
            Spacer()
            if model.page != .welcome {
                Button("Back") { model.go(OnboardingPage(rawValue: model.page.rawValue - 1) ?? .welcome, reduceMotion: reduceMotion) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(OnboardingStyle.foamSoft)
                    .padding(.horizontal, 10)
            }
            Button(primaryTitle, action: primary)
                .buttonStyle(MarmaladeButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 36)
        .frame(height: 76)
        .background(OnboardingStyle.harborDeep.opacity(0.55))
        .overlay(alignment: .top) { Rectangle().fill(OnboardingStyle.foam.opacity(0.07)).frame(height: 1) }
    }

    private var primaryTitle: String {
        switch model.page {
        case .welcome: return "Get Started"
        case .permissions: return "Continue"
        case .done: return "Start Using tabby"
        }
    }

    private func primary() {
        switch model.page {
        case .welcome: model.go(.permissions, reduceMotion: reduceMotion)
        case .permissions: model.go(.done, reduceMotion: reduceMotion)
        case .done: finish()
        }
    }
}

struct MarmaladeButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12.5 : 14, weight: .semibold))
            .foregroundStyle(OnboardingStyle.harborDeep)
            .padding(.horizontal, compact ? 14 : 22)
            .frame(height: compact ? 28 : 36)
            .background(Capsule().fill(OnboardingStyle.marmalade.opacity(configuration.isPressed ? 0.82 : 1)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            CatMark(blinks: true)
                .frame(width: 92, height: 92)
                .shadow(color: OnboardingStyle.marmalade.opacity(0.35), radius: 26)
                .accessibilityHidden(true)
            Text("Welcome to tabby")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .padding(.top, 22)
            Text("Every Claude Code tab, at a glance: a name, a calm color and a live status for each session.")
                .font(.system(size: 15))
                .foregroundStyle(OnboardingStyle.foamSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 8)
            HStack(alignment: .top, spacing: 14) {
                FeatureTile(symbol: "capsule.fill", title: "The island",
                            detail: "Every session at the top of your screen. Click one to jump to its tab.")
                FeatureTile(symbol: "square.grid.2x2.fill", title: "Tiling",
                            detail: "One key splits tabs into windows and fills the screen with them.")
                FeatureTile(symbol: "textformat", title: "Watermark",
                            detail: "Each session's topic, large and faint, across its window.")
            }
            .padding(.top, 34)
        }
        .padding(.horizontal, 40)
    }
}

private struct FeatureTile: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingStyle.marmalade)
                .frame(width: 32, height: 32)
                .background(Circle().fill(OnboardingStyle.marmalade.opacity(0.16)))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(OnboardingStyle.foamSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 196, height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(OnboardingStyle.foam.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(OnboardingStyle.foam.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Permissions

private struct PermissionsPage: View {
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var state: SettingsState
    let island: IslandController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(permissions.nothingNeeded ? "No permissions needed" : "A few permissions")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
                if !permissions.nothingNeeded && permissions.canAskAll {
                    Button("Allow All") { permissions.requestAll() }
                        .buttonStyle(MarmaladeButtonStyle(compact: true))
                        .accessibilityHint("Asks macOS for each permission below, one after another")
                }
            }
            Text(permissions.nothingNeeded
                 ? "Your terminal works with the island as it is: it lists every session and brings the right app forward. Tiling and the watermark are for Terminal and iTerm2."
                 : "macOS asks for each one once. tabby uses them only to arrange windows, jump to tabs and find each session's window. Nothing leaves your Mac.")
                .font(.system(size: 14))
                .foregroundStyle(OnboardingStyle.foamSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            VStack(spacing: 10) {
                if permissions.accessibilityNeeded {
                    PermissionCard(symbol: "hand.raised.fill", title: "Accessibility",
                                   detail: "Tiling splits tabs into their own windows and brings full-screen windows back.",
                                   status: permissions.accessibility,
                                   hint: "Switch on Tabby Island in System Settings › Privacy & Security › Accessibility.",
                                   allow: { permissions.requestAccessibility() },
                                   askAgain: { permissions.requestAccessibility() },
                                   openSettings: PermissionCenter.openAccessibilityPane)
                }
                if permissions.isNeeded(.terminal) {
                    PermissionCard(symbol: "terminal.fill", title: "Control Terminal",
                                   detail: "Jump to a session's tab, and put its watermark on the right window.",
                                   status: permissions.status(of: .terminal),
                                   hint: "Click Allow in the dialog macOS shows.",
                                   allow: { permissions.requestAutomation(.terminal) },
                                   askAgain: { permissions.askAgain(.terminal) },
                                   openSettings: PermissionCenter.openAutomationPane,
                                   deniedHint: PermissionCenter.deniedHint(.terminal))
                }
                if permissions.isNeeded(.iTerm) {
                    PermissionCard(symbol: "terminal", title: "Control iTerm2",
                                   detail: "Jump to a session's tab in iTerm2 and read its tab titles.",
                                   status: permissions.status(of: .iTerm),
                                   hint: "Click Allow in the dialog macOS shows.",
                                   allow: { permissions.requestAutomation(.iTerm) },
                                   askAgain: { permissions.askAgain(.iTerm) },
                                   openSettings: PermissionCenter.openAutomationPane,
                                   deniedHint: PermissionCenter.deniedHint(.iTerm))
                }
                if permissions.isNeeded(.systemEvents) {
                    PermissionCard(symbol: "rectangle.split.2x1.fill", title: "Control System Events",
                                   detail: "Tiling clicks Terminal's “Move Tab to New Window” for you.",
                                   status: permissions.status(of: .systemEvents),
                                   hint: "Click Allow in the dialog macOS shows.",
                                   allow: { permissions.requestAutomation(.systemEvents) },
                                   askAgain: { permissions.askAgain(.systemEvents) },
                                   openSettings: PermissionCenter.openAutomationPane,
                                   deniedHint: PermissionCenter.deniedHint(.systemEvents))
                }
                LoginCard(on: state.loginItem) { island.setLoginItem($0) }
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 44)
    }
}

private struct PermissionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let status: PermissionCenter.Status
    let hint: String
    let allow: () -> Void
    let askAgain: () -> Void
    let openSettings: () -> Void
    /// Where to switch it on after a "Don't Allow" (Automation cards): shown then, with Open Settings.
    var deniedHint: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            CardIcon(symbol: symbol, done: status == .allowed)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(status == .waiting ? hint : status == .denied ? deniedHint ?? detail : detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(status == .waiting || (status == .denied && deniedHint != nil)
                                     ? OnboardingStyle.foam.opacity(0.9) : OnboardingStyle.foamSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if status == .waiting || (status == .denied && deniedHint == nil) {
                    Button("Open System Settings", action: openSettings)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OnboardingStyle.marmalade)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingStyle.foam.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(status == .allowed ? OnboardingStyle.moss.opacity(0.35) : OnboardingStyle.foam.opacity(0.08)))
        .animation(.easeOut(duration: 0.2), value: status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(statusLabel)")
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .allowed:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnboardingStyle.moss)
        case .waiting:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Waiting…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingStyle.foamSoft)
            }
        case .denied:
            HStack(spacing: 10) {
                Text("Not allowed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingStyle.warning)
                Button(deniedHint == nil ? "Ask Again" : "Open Settings", action: askAgain)
                    .buttonStyle(MarmaladeButtonStyle(compact: true))
            }
        case .notAsked, .unknown:
            Button("Allow", action: allow)
                .buttonStyle(MarmaladeButtonStyle(compact: true))
        }
    }

    private var statusLabel: String {
        switch status {
        case .allowed: return "allowed"
        case .waiting: return "waiting"
        case .denied: return "not allowed"
        case .notAsked, .unknown: return "not allowed yet"
        }
    }
}

private struct CardIcon: View {
    let symbol: String
    let done: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnboardingStyle.marmalade)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(OnboardingStyle.marmalade.opacity(0.15)))
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(OnboardingStyle.moss, OnboardingStyle.harborDeep)
                    .offset(x: 5, y: 5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LoginCard: View {
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            CardIcon(symbol: "power", done: false)
            VStack(alignment: .leading, spacing: 3) {
                Text("Open at login")
                    .font(.system(size: 14, weight: .semibold))
                Text("Start Tabby Island when you log in, so the island is always there.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(OnboardingStyle.foamSoft)
            }
            Spacer(minLength: 12)
            Toggle("Open at login", isOn: Binding(get: { on }, set: { set($0) }))
                .toggleStyle(.switch)
                .tint(OnboardingStyle.marmalade)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingStyle.foam.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(OnboardingStyle.foam.opacity(0.08)))
    }
}

// MARK: - Done

private struct DonePage: View {
    @ObservedObject var permissions: PermissionCenter
    let config: IslandConfig

    var body: some View {
        let ready = permissions.allGranted
        VStack(spacing: 0) {
            IslandSketch()
                .padding(.top, 4)
            Text(ready ? "You're all set" : "Almost there")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .padding(.top, 22)
            Text("Hover the top of your screen for every session. These work from any app:")
                .font(.system(size: 14.5))
                .foregroundStyle(OnboardingStyle.foamSoft)
                .padding(.top, 6)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 11) {
                GridRow {
                    shortcut(.toggle, "open the island")
                    shortcut(.next, "the session that needs you")
                }
                GridRow {
                    shortcut(.tile, "tile your windows")
                    shortcut(.watermark, "watermark on or off")
                }
                GridRow {
                    shortcut(.jump, "jump to a session")
                    shortcut(.settings, "Settings")
                }
            }
            .padding(.top, 24)
            if !ready {
                Label("Tiling and the watermark need the permissions from the step before. Settings › Permissions has them any time.",
                      systemImage: "info.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(OnboardingStyle.warning)
                    .frame(maxWidth: 520)
                    .padding(.top, 22)
            }
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func shortcut(_ action: ShortcutAction, _ label: String) -> some View {
        if let combo = config.shortcuts[action], config.hotkeys {
            HStack(spacing: 10) {
                Text(action.display(combo))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(minWidth: 70, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(OnboardingStyle.foam.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(OnboardingStyle.foam.opacity(0.12)))
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(OnboardingStyle.foam.opacity(0.9))
            }
        }
    }
}

/// The collapsed island, drawn: a black pill with a few session dots, one of them ringing.
private struct IslandSketch: View {
    private let dots: [Color] = [Color(hexString: "#7cc4f0"), Color(hexString: "#f59ab1"),
                                 Color(hexString: "#a7d98f"), OnboardingStyle.marmalade]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<dots.count, id: \.self) { index in
                    Circle()
                        .fill(dots[index])
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: Palette.waitingNS), lineWidth: index == 3 ? 1.6 : 0)
                            .frame(width: 15, height: 15))
                }
                Spacer(minLength: 0)
                Image(systemName: "bell.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Palette.waitingNS))
                Text("1")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: Palette.waitingNS))
            }
            .padding(.horizontal, 16)
            .frame(width: 250, height: 34)
            .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14, bottomTrailingRadius: 14,
                                               topTrailingRadius: 0, style: .continuous).fill(Color.black))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            Label("hover here", systemImage: "arrow.up")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OnboardingStyle.foamSoft)
        }
        .accessibilityHidden(true)
    }
}
