import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - A floating panel that takes the keyboard

/// Borderless and non-activating, like Spotlight: it takes typing while the app you were in
/// stays in front, and closes when it loses the keyboard.
final class FloatingKeyPanel: NSPanel {
    /// Keys the panel handles itself (arrows, Return, Escape, ⌘ shortcuts); return true when used.
    var onKey: ((NSEvent) -> Bool)?

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let onKey, onKey(event) { return }
        super.sendEvent(event)
    }

    /// On the screen with the pointer: centered, its top a little above the middle.
    func present(size: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.2 - size.height)
        setFrame(NSRect(origin: origin, size: size), display: true)
        makeKeyAndOrderFront(nil)
    }
}

/// The dark, rounded look of the island, for its floating panels.
struct IslandCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

enum Keys {
    static func plain(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }
}

// MARK: - Model

@MainActor
final class QuickLaunchModel: ObservableObject {
    @Published var folders: [RecentFolder] = []
    @Published var query = "" { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var name = ""
    @Published var skipPermissions = false
    @Published var loading = false
    @Published var launching = false
    /// Clicked or pressed Return: set by the controller.
    var launch: (RecentFolder) -> Void = { _ in }

    var results: [RecentFolder] { QuickLaunchFilter.apply(query, to: folders) }
    var selected: RecentFolder? { results.indices.contains(selection) ? results[selection] : nil }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }
}

// MARK: - Controller

/// ⌃⌥L: start Claude in a recent or frequent folder, in a new terminal window on your Claude
/// screens, optionally skipping permissions.
@MainActor
final class QuickLaunchController: NSObject, NSWindowDelegate {
    static let shared = QuickLaunchController()
    static let size = CGSize(width: 620, height: 470)

    let model = QuickLaunchModel()
    private lazy var panel: FloatingKeyPanel = {
        let panel = FloatingKeyPanel(size: Self.size)
        panel.contentView = NSHostingView(rootView: QuickLaunchView(model: model))
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        return panel
    }()
    private var loadedAt = Date.distantPast

    func toggle(island: IslandController) {
        if panel.isVisible { return close() }
        show(island: island)
    }

    func show(island: IslandController) {
        model.query = ""
        model.name = ""
        model.selection = 0
        model.launching = false
        model.skipPermissions = island.config.launchSkipPermissions
        model.launch = { [weak self, weak island] folder in
            guard let self, let island else { return }
            self.start(folder, island: island)
        }
        panel.present(size: Self.size)
        reload()
    }

    func close() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    /// `tabby new --list --json` (the last list shows meanwhile).
    private func reload() {
        guard Date().timeIntervalSince(loadedAt) > 2 else { return }
        loadedAt = Date()
        model.loading = model.folders.isEmpty
        // Every recent folder the panel can filter, not just the first 20 `--list` shows.
        Actions.runCLI(["new", "--list", "--json", "--limit=200"]) { [weak self] status, output in
            guard let self else { return }
            self.model.loading = false
            if status == 0 { self.model.folders = RecentFolder.parse(output) }
        }
    }

    private func start(_ folder: RecentFolder, island: IslandController) {
        guard !model.launching else { return }
        model.launching = true
        if model.skipPermissions != island.config.launchSkipPermissions {
            island.setSetting("launchSkipPermissions", .bool(model.skipPermissions))
        }
        let args = QuickLaunchFilter.arguments(for: folder, name: model.name, skipPermissions: model.skipPermissions)
        close()
        Actions.runCLI(args) { [weak island] status, output in
            let line = output.split(separator: "\n").first.map(String.init) ?? ""
            if status != 0 || !line.hasPrefix("Opened") {
                island?.enqueue(.info(line.isEmpty ? "Could not start a session" : line, symbol: "exclamationmark.triangle.fill",
                                      topic: "launch", detail: output), force: true)
            }
        }
        loadedAt = .distantPast
    }

    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
            return true
        case kVK_DownArrow where Keys.plain(event):
            model.move(1)
            return true
        case kVK_UpArrow where Keys.plain(event):
            model.move(-1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let folder = model.selected { model.launch(folder) }
            return true
        case kVK_ANSI_D where command:
            model.skipPermissions.toggle()
            return true
        case kVK_ANSI_W where command:
            close()
            return true
        default:
            return false
        }
    }
}

// MARK: - View

struct QuickLaunchView: View {
    @ObservedObject var model: QuickLaunchModel
    @FocusState private var focus: Field?
    private enum Field { case search, name }

    var body: some View {
        IslandCard {
            VStack(spacing: 0) {
                search
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                results
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                footer
            }
        }
        .frame(width: QuickLaunchController.size.width, height: QuickLaunchController.size.height)
        .onAppear { focus = .search }
    }

    private var search: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(nsColor: Brand.marmalade))
            TextField("Start Claude in…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .focused($focus, equals: .search)
            if model.loading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private var results: some View {
        let rows = model.results
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, folder in
                        FolderRow(folder: folder, selected: index == model.selection)
                            .id(folder.id)
                            .onTapGesture { model.launch(folder) }
                            .onHover { if $0 { model.selection = index } }
                    }
                }
                .padding(8)
            }
            .overlay {
                if rows.isEmpty && !model.loading {
                    VStack(spacing: 6) {
                        Text(model.query.isEmpty ? "No recent folders yet" : "No folder matches “\(model.query)”")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Type a path, like ~/Dev/app. Folders you run Claude in show up here.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .onChange(of: model.selection) { _, index in
                if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    TextField("Name (optional)", text: $model.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($focus, equals: .name)
                }
                .padding(.horizontal, 10)
                .frame(width: 190, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
                Toggle(isOn: $model.skipPermissions) {
                    Text("Skip permissions").font(.system(size: 12.5, weight: .medium))
                }
                .toggleStyle(.checkbox)
                .help("Starts claude with --dangerously-skip-permissions: it runs every tool (commands, edits) without asking first. Only for folders you trust. ⌘D")
                Text("⌘D").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Text("↩").font(.system(size: 12, weight: .semibold))
                    Text("Start").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Color(nsColor: Brand.marmalade))
            }
            if model.skipPermissions {
                Label("Claude won't ask before it runs commands or edits files in this session.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.warn)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.15), value: model.skipPermissions)
    }
}

private struct FolderRow: View {
    let folder: RecentFolder
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: folder.typed ? "folder.badge.plus" : "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(selected ? Color(nsColor: Brand.marmalade) : .white.opacity(0.55))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.1 : 0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text(folder.display)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            if !folder.typed {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(folder.countText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(folder.live > 0 ? Palette.done : .white.opacity(0.6))
                    Text(folder.agoText())
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.1 : 0)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(folder.display), \(folder.countText)")
        .accessibilityAddTraits(.isButton)
    }
}
