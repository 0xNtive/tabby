import AppKit

// Focus mode's cover: an opaque panel over a Terminal window's content, in the tab's own
// background color. A box drawn in box-drawing characters holds the session's topic in large
// letters; under it, one line per running agent with a spinner, the step it's on and how long it
// has run. A cover that stays when it's your turn (`focusIdle`) shows the gist of Claude's reply
// instead (how it opens, and what it asks) with a "Show full reply" button.
// WatermarkController places it (Watermark.swift); FocusRule decides when (FocusMode.swift).

// MARK: - Content

/// What one session's cover shows.
struct FocusCoverContent: Equatable {
    var sessionId: String
    var title: String
    var project: String
    var background: NSColor
    var foreground: NSColor
    var accent: NSColor
    /// The main agent's line: the step it's on ("Editing tile.js"), else its task, else "Working".
    var mainText: String
    /// The task from Claude's task list, when the step takes the main line.
    var task: String?
    /// "~2m left", "2 of 5 tasks · ~3m left", when there's a guess.
    var mainDetail: String?
    /// When this turn's work began (seconds since 1970).
    var turnStartedAt: TimeInterval?
    var agents: [FocusAgent]
    /// Claude is done and it's your turn: the cover shows a "Your turn" button, not what's running.
    var yourTurn = false
    /// When Claude finished (seconds since 1970).
    var doneAt: TimeInterval?
    /// Your turn: the gist of Claude's reply.
    var reply: ReplySummary?

    static func make(_ session: IslandSession, themes: [ThemeInfo], globalTheme: String?, now: Date = Date()) -> FocusCoverContent {
        let theme = themes.first { $0.id == (session.theme ?? globalTheme) }
        let background = NSColor(hexString: session.bgHex ?? theme?.bg) ?? NSColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: 1)
        let foreground = NSColor(hexString: session.fgHex ?? theme?.fg) ?? NSColor(white: 0.88, alpha: 1)
        let accent = NSColor(hexString: session.cursorHex ?? session.accentHex ?? session.dotHex) ?? foreground
        let progress = session.progress(now: now)
        let yourTurn = session.status == .idle
        let task = session.tasks?.current.map { Fmt.oneLine($0, max: 120) }
        let took = session.lastTurnMs.flatMap { $0 >= 1500 ? FocusCoverView.elapsed($0 / 1000) : nil }
        return FocusCoverContent(
            sessionId: session.id, title: session.title, project: session.project,
            background: background, foreground: foreground, accent: accent,
            mainText: yourTurn ? (took.map { "Done in \($0)" } ?? "Done") : session.activity ?? task ?? "Working",
            task: yourTurn || session.activity == nil ? nil : task,
            mainDetail: progress?.brief,
            turnStartedAt: session.workElapsed(now: now).map { now.timeIntervalSince1970 - $0 },
            agents: yourTurn ? [] : session.agents,
            yourTurn: yourTurn,
            doneAt: yourTurn ? session.activityAt.map { $0 / 1000 } : nil,
            reply: yourTurn ? session.reply : nil
        )
    }

    /// What the box shows changed (not just the running lines).
    func sameCard(as other: FocusCoverContent?) -> Bool {
        guard let other else { return false }
        return title == other.title && project == other.project && background == other.background &&
            foreground == other.foreground && accent == other.accent && yourTurn == other.yourTurn &&
            reply == other.reply && (task == nil) == (other.task == nil)
    }

    /// Lines under the box while Claude works: Claude, its task (when there's room), its subagents.
    var rowCount: Int { 1 + (task == nil ? 0 : 1) + agents.count }
}

// MARK: - Terminal's window chrome

/// How much of a Terminal window's top the title bar (and, with several tabs, the tab bar) takes.
@MainActor
enum TerminalChrome {
    static let titleBar: CGFloat = {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let frame = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: style)
        return max(22, frame.height - 300)
    }()

    /// Measured once on two tabbed windows that are never shown.
    static let tabBar: CGFloat = {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let rect = NSRect(x: -30_000, y: -30_000, width: 400, height: 300)
        let a = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        let b = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        a.isReleasedWhenClosed = false
        b.isReleasedWhenClosed = false
        a.tabbingMode = .preferred
        b.tabbingMode = .preferred
        a.addTabbedWindow(b, ordered: .above)
        let front = a.tabGroup?.selectedWindow ?? a
        let measured = front.frame.height - front.contentLayoutRect.height - titleBar
        a.close()
        b.close()
        return measured > 12 && measured < 80 ? measured : 32
    }()

    /// A window filling a screen: exactly its frame, or on a display with a notch, all of it
    /// below the notch (where macOS puts full-screen windows there). `screens`: each screen's
    /// frame and its safe-area top inset.
    static func isFullScreen(_ frame: CGRect, screens: [(frame: CGRect, topInset: CGFloat)]) -> Bool {
        screens.contains { screen in
            if frame == screen.frame { return true }
            guard screen.topInset > 0 else { return false }
            var below = screen.frame
            below.size.height -= screen.topInset
            return abs(frame.minX - below.minX) < 1 && abs(frame.minY - below.minY) < 1
                && abs(frame.width - below.width) < 1 && abs(frame.height - below.height) < 1
        }
    }

    /// Bottom corners of a window, so the cover doesn't poke past them.
    static var cornerRadius: CGFloat {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 10
    }
}

// MARK: - Drawing

/// Where everything on a cover goes, for one size and content.
struct FocusLayout {
    var compact: Bool
    var cell: NSFont
    var cellWidth: CGFloat
    var lineHeight: CGFloat
    /// The box, in whole character cells; its frame runs through the middle of its edge cells,
    /// the way a terminal draws ╭─╮ │ ╰─╯.
    var box: CGRect
    var title: NSAttributedString
    var titleRect: CGRect
    /// The project, set into the box's top edge like a panel title in a terminal UI.
    var label: NSAttributedString?
    var labelOrigin: CGPoint
    /// The agent lines under the box, one per `rowHeight`.
    var lines: CGRect
    var rowHeight: CGFloat
    var maxLines: Int
    var hint: NSAttributedString?
    var hintRect: CGRect
    /// The "Show full reply" button (your turn only, where there's room for it).
    var button: NSAttributedString?
    var buttonRect = CGRect.zero
    /// Your turn: the gist of the reply, under the "Done" line.
    var summary: NSAttributedString?
    var summaryRect = CGRect.zero

    static let spinner = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    static func titleFont(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .bold) }

    static func paragraph(_ alignment: NSTextAlignment, lineHeight: CGFloat = 1) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        style.lineHeightMultiple = lineHeight
        return style
    }

    /// The reply's opening, then what it asks (in the session's color), when `ask`.
    static func summary(_ reply: ReplySummary, content: FocusCoverContent, font: NSFont, lineHeight: CGFloat,
                        ask: Bool) -> NSAttributedString {
        let body = NSMutableParagraphStyle()
        body.lineBreakMode = .byWordWrapping
        body.lineHeightMultiple = 1.1
        let string = NSMutableAttributedString(string: reply.lead, attributes: [
            .font: font, .foregroundColor: content.foreground.withAlphaComponent(0.8), .paragraphStyle: body,
        ])
        if ask, let question = reply.ask {
            let spaced = body.mutableCopy() as! NSMutableParagraphStyle
            spaced.paragraphSpacingBefore = (lineHeight * 0.6).rounded()
            string.append(NSAttributedString(string: "\n→ " + question, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .medium),
                .foregroundColor: content.accent, .paragraphStyle: spaced,
            ]))
        }
        return string
    }

    static func height(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    /// The tallest summary that fits in `room`: with its question, without, or the opening cut to
    /// whole lines. Nil when not even a line fits.
    static func fit(_ reply: ReplySummary, content: FocusCoverContent, font: NSFont, lineHeight: CGFloat,
                    width: CGFloat, room: CGFloat) -> (NSAttributedString, CGFloat)? {
        let line = ceil(lineHeight * 1.1)
        guard width > 80, room >= line else { return nil }
        let full = summary(reply, content: content, font: font, lineHeight: lineHeight, ask: true)
        let fullHeight = height(full, width: width)
        if fullHeight <= room { return (full, fullHeight) }
        let lead = summary(reply, content: content, font: font, lineHeight: lineHeight, ask: false)
        let leadHeight = height(lead, width: width)
        if leadHeight <= room { return (lead, leadHeight) }
        return (lead, (room / line).rounded(.down) * line)
    }

    /// `bounds`: the cover (flipped: top-left origin). `agentCount`: lines to make room for.
    static func make(_ content: FocusCoverContent, in bounds: CGRect, agentCount: Int) -> FocusLayout? {
        let width = bounds.width, height = bounds.height
        guard width > 120, height > 60 else { return nil }
        let words = content.title.split(whereSeparator: \.isWhitespace).map(String.init)
        let title = words.joined(separator: " ")
        guard !title.isEmpty else { return nil }
        let longest = words.max { $0.count < $1.count } ?? title

        let cellSize = min(max((min(height * 0.026, width * 0.021)).rounded(), 11), 16)
        let cell = NSFont.monospacedSystemFont(ofSize: cellSize, weight: .regular)
        let cellWidth = ("─" as NSString).size(withAttributes: [.font: cell]).width
        let lineHeight = ceil(cell.ascender - cell.descender + cell.leading)
        let margin = max(24, (width * 0.06).rounded())
        let compact = height < 230 || width < 320

        // The title: as large as fits in two lines, never breaking a word, well under the
        // watermark's size.
        let padX = compact ? 0 : cellWidth * 4
        let maxWidth = width - margin * 2 - padX * 2
        let maxHeight = compact ? height * (content.yourTurn ? 0.5 : 0.7) : height * 0.3
        func attributed(_ size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: title, attributes: [
                .font: titleFont(size), .foregroundColor: content.foreground,
                .paragraphStyle: paragraph(.center, lineHeight: 0.95), .kern: -size * 0.015,
            ])
        }
        func measure(_ size: CGFloat) -> CGSize? {
            let string = attributed(size)
            let box = string.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading])
            let line = titleFont(size).ascender - titleFont(size).descender
            let word = NSAttributedString(string: longest, attributes: [.font: titleFont(size), .kern: -size * 0.015]).size().width
            guard box.height <= maxHeight, box.height <= line * 2.3, word <= maxWidth else { return nil }
            return CGSize(width: ceil(box.width), height: ceil(box.height))
        }
        var low: CGFloat = 12
        var high = min(max(height * (compact ? 0.3 : 0.11), 20), 96)
        guard high > low, measure(low) != nil else { return nil }
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if measure(mid) != nil { low = mid } else { high = mid }
        }
        let size = low.rounded(.down)
        let titleSize = measure(size) ?? measure(low) ?? CGSize(width: maxWidth, height: size)
        let titleString = attributed(size)

        // Your turn: a button in the session's color, the one thing on the cover to act on. The
        // short label where the long one doesn't fit.
        var button: NSAttributedString?
        var buttonSize = CGSize.zero
        if content.yourTurn {
            let labels = content.reply.map { reply in
                (reply.lines > 3 ? ["Show full reply · \(reply.lines) lines"] : []) + ["Show full reply", "Show reply"]
            } ?? ["Your turn · click to reply", "Your turn"]
            for text in labels {
                let string = NSAttributedString(string: text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: cellSize, weight: .bold), .foregroundColor: content.background,
                ])
                let size = CGSize(width: ceil(string.size().width + cellWidth * 4), height: ceil(lineHeight * 2.2))
                guard size.width <= width - margin * 2 else { continue }
                button = string
                buttonSize = size
                break
            }
        }

        if compact {
            var rect = CGRect(x: (width - maxWidth) / 2, y: ((height - titleSize.height) / 2).rounded(),
                              width: maxWidth, height: titleSize.height + 2)
            var buttonRect = CGRect.zero
            var summary: NSAttributedString?
            var summaryRect = CGRect.zero
            let total = titleSize.height + lineHeight + buttonSize.height
            if button != nil, total <= height * 0.9 {
                // Room left: the reply's opening between the title and the button, two lines at most.
                let spare = min(height * 0.9 - total - lineHeight, ceil(lineHeight * 1.1) * 2)
                let fitted = content.reply.flatMap {
                    fit($0, content: content, font: cell, lineHeight: lineHeight, width: maxWidth, room: spare)
                }
                let summaryHeight = fitted.map { $0.1 + lineHeight } ?? 0
                rect.origin.y = ((height - total - summaryHeight) / 2).rounded()
                if let fitted {
                    summary = fitted.0
                    summaryRect = CGRect(x: rect.minX, y: (rect.maxY + lineHeight).rounded(), width: maxWidth, height: fitted.1)
                }
                buttonRect = CGRect(x: ((width - buttonSize.width) / 2).rounded(),
                                    y: (rect.maxY + summaryHeight + lineHeight).rounded(),
                                    width: buttonSize.width, height: buttonSize.height)
            } else {
                button = nil
            }
            return FocusLayout(compact: true, cell: cell, cellWidth: cellWidth, lineHeight: lineHeight, box: .zero,
                               title: titleString, titleRect: rect, label: nil, labelOrigin: .zero, lines: .zero,
                               rowHeight: lineHeight, maxLines: 0, hint: nil, hintRect: .zero,
                               button: button, buttonRect: buttonRect, summary: summary, summaryRect: summaryRect)
        }

        let label = content.project.isEmpty ? nil : NSAttributedString(string: " \(content.project) ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: cellSize, weight: .medium),
            .foregroundColor: content.foreground.withAlphaComponent(0.62),
        ])

        // The box, snapped to whole cells, as wide as the title needs (at least 36 cells).
        let widest = max(titleSize.width, (label?.size().width ?? 0) + cellWidth * 4)
        let available = Int(((width - margin * 2) / cellWidth).rounded(.down))
        let wanted = Int(ceil((widest + padX * 2) / cellWidth)) + 2
        // A reply's gist reads better on longer lines.
        let columns = max(min(max(wanted, content.reply != nil ? 56 : 36), available), 12)
        let inner = lineHeight * 2.4 * 2 + titleSize.height
        let rows = max(Int(ceil(inner / lineHeight)), 5)
        let boxSize = CGSize(width: CGFloat(columns) * cellWidth, height: CGFloat(rows) * lineHeight)

        // Lines under it, then a hint at the bottom; the whole group sits just above center.
        let gap = lineHeight * 1.5
        let rowHeight = ceil(lineHeight * 1.5)
        let hintFont = NSFont.monospacedSystemFont(ofSize: max(10, cellSize - 2), weight: .regular)
        let hint = NSAttributedString(string: "focus mode · click to open", attributes: [
            .font: hintFont, .foregroundColor: content.foreground.withAlphaComponent(0.28), .paragraphStyle: paragraph(.center),
        ])
        let hintHeight = ceil(hint.size().height)
        let room = height - boxSize.height - gap - hintHeight - lineHeight * 3
        var maxLines = max(0, min(6, Int((room / rowHeight).rounded(.down))))
        var summary: NSAttributedString?
        var summaryHeight: CGFloat = 0
        let summaryGap = (lineHeight * 0.5).rounded()
        if content.yourTurn {
            // One line (done, and when), the reply's gist, then the button; the button alone
            // where room is short.
            if room < buttonSize.height { button = nil }
            maxLines = room >= rowHeight + lineHeight + buttonSize.height || button == nil ? min(maxLines, 1) : 0
            let left = room - CGFloat(maxLines) * rowHeight - (button != nil ? lineHeight + buttonSize.height : 0) - summaryGap
            if maxLines > 0, let reply = content.reply,
               let fitted = fit(reply, content: content, font: cell, lineHeight: lineHeight,
                                width: boxSize.width - cellWidth * 4, room: min(left, ceil(lineHeight * 1.1) * 7 + lineHeight)) {
                summary = fitted.0
                summaryHeight = fitted.1
            }
        }
        let shownLines = min(max(content.yourTurn ? 1 : agentCount, 1), maxLines)
        let linesHeight = shownLines > 0 ? gap + CGFloat(shownLines) * rowHeight : 0
        let summaryBlock = summary != nil ? summaryGap + summaryHeight : 0
        let buttonGap = shownLines > 0 ? lineHeight : gap
        let group = boxSize.height + linesHeight + summaryBlock + (button != nil ? buttonGap + buttonSize.height : 0)
        let top = max(lineHeight, ((height - group) * 0.44).rounded())
        let box = CGRect(x: ((width - boxSize.width) / 2).rounded(), y: top, width: boxSize.width, height: boxSize.height)

        let titleRect = CGRect(x: box.minX + cellWidth, y: box.minY + ((box.height - titleSize.height) / 2).rounded() - 1,
                               width: box.width - cellWidth * 2, height: titleSize.height + 2)
        let labelOrigin = CGPoint(x: box.minX + cellWidth * 2, y: box.minY)
        let lines = CGRect(x: box.minX + cellWidth, y: box.maxY + gap, width: box.width - cellWidth * 2,
                           height: CGFloat(maxLines) * rowHeight)
        let hintRect = CGRect(x: 0, y: height - hintHeight - lineHeight * 1.2, width: width, height: hintHeight)
        let summaryRect = summary == nil ? .zero : CGRect(
            x: box.minX + cellWidth * 2, y: (box.maxY + linesHeight + summaryGap).rounded(),
            width: box.width - cellWidth * 4, height: summaryHeight)
        let buttonRect = button == nil ? .zero : CGRect(
            x: ((width - buttonSize.width) / 2).rounded(), y: (box.maxY + linesHeight + summaryBlock + buttonGap).rounded(),
            width: buttonSize.width, height: buttonSize.height)
        // The hint at the bottom only where nothing above runs into it.
        let clear = max(box.maxY + linesHeight + summaryBlock, buttonRect.maxY) + lineHeight <= hintRect.minY
        return FocusLayout(compact: false, cell: cell, cellWidth: cellWidth, lineHeight: lineHeight, box: box,
                           title: titleString, titleRect: titleRect, label: label, labelOrigin: labelOrigin,
                           lines: lines, rowHeight: rowHeight, maxLines: maxLines,
                           hint: room > lineHeight * 2 && clear ? hint : nil, hintRect: hintRect,
                           button: button, buttonRect: buttonRect, summary: summary, summaryRect: summaryRect)
    }
}

/// The cover's view: shared by the overlay windows, the Settings preview and snapshots.
final class FocusCoverView: NSView {
    var content: FocusCoverContent? {
        didSet {
            guard content != oldValue else { return }
            if content?.sameCard(as: oldValue) == true, content?.rowCount == oldValue?.rowCount {
                setNeedsDisplay(layout?.lines.insetBy(dx: -4, dy: -4) ?? bounds)
            } else {
                invalidate()
            }
        }
    }
    /// Spinner frame; advanced by the controller while the cover shows.
    var frameIndex = 0
    /// Spinners stand still (Reduce Motion).
    var still = false
    /// Round the bottom corners like the window under it (not in full screen).
    var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue { needsDisplay = true } } }
    /// Seconds since 1970, for the elapsed times; nil means now (tests pin it).
    var clock: TimeInterval?
    var onClick: (() -> Void)?

    private var layoutCache: (size: CGSize, agents: Int, layout: FocusLayout?)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var layout: FocusLayout? {
        guard let content else { return nil }
        let agents = max(content.rowCount, 1)
        if let cache = layoutCache, cache.size == bounds.size, cache.agents == agents { return cache.layout }
        let layout = FocusLayout.make(content, in: bounds, agentCount: agents)
        layoutCache = (bounds.size, agents, layout)
        return layout
    }

    private func invalidate() {
        layoutCache = nil
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if layoutCache?.size != newSize { invalidate() }
    }

    /// Next spinner frame: only the lines are drawn again.
    func advance() {
        frameIndex &+= 1
        if let lines = layout?.lines, lines.height > 0 { setNeedsDisplay(lines.insetBy(dx: -4, dy: -2)) }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        let background = NSBezierPath()
        let r = min(cornerRadius, bounds.height / 4)
        background.move(to: NSPoint(x: bounds.minX, y: bounds.minY))
        background.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        background.appendArc(from: NSPoint(x: bounds.maxX, y: bounds.maxY), to: NSPoint(x: bounds.maxX - r, y: bounds.maxY), radius: r)
        background.appendArc(from: NSPoint(x: bounds.minX, y: bounds.maxY), to: NSPoint(x: bounds.minX, y: bounds.maxY - r), radius: r)
        background.close()
        content.background.setFill()
        background.fill()
        guard let layout else { return }

        if dirtyRect.intersects(layout.box) || dirtyRect.intersects(layout.titleRect) || layout.compact {
            if !layout.compact { drawBox(layout, content) }
            layout.title.draw(with: layout.titleRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        if let hint = layout.hint, dirtyRect.intersects(layout.hintRect) {
            hint.draw(with: layout.hintRect, options: [.usesLineFragmentOrigin])
        }
        if layout.maxLines > 0, dirtyRect.intersects(layout.lines) { drawLines(layout, content) }
        if let summary = layout.summary, dirtyRect.intersects(layout.summaryRect) {
            summary.draw(with: layout.summaryRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
        if let button = layout.button, dirtyRect.intersects(layout.buttonRect) {
            // Filled with the session's color, its label in the tab's own background.
            let radius = layout.cellWidth * 0.7
            content.accent.setFill()
            NSBezierPath(roundedRect: layout.buttonRect, xRadius: radius, yRadius: radius).fill()
            let size = button.size()
            button.draw(at: NSPoint(x: (layout.buttonRect.midX - size.width / 2).rounded(),
                                    y: (layout.buttonRect.midY - size.height / 2).rounded()))
        }
    }

    /// ╭─ project ──╮ │ │ ╰──╯ in the session's color, drawn the way a terminal joins box-drawing
    /// characters: one line through the middle of the edge cells, rounded at the corners.
    private func drawBox(_ layout: FocusLayout, _ content: FocusCoverContent) {
        let cw = layout.cellWidth
        let lh = layout.lineHeight
        let scale = window?.backingScaleFactor ?? 2
        // Crisp: a line an odd number of pixels wide is centered on a pixel, an even one between.
        let pixels = max(2, (layout.cell.pointSize / 10 * scale).rounded())
        let width = pixels / scale
        let odd = Int(pixels) % 2 == 1
        func snap(_ v: CGFloat) -> CGFloat { ((v * scale).rounded(.down) + (odd ? 0.5 : 0)) / scale }
        func whole(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let frame = CGRect(x: snap(layout.box.minX + cw / 2), y: snap(layout.box.minY + lh / 2),
                           width: whole(layout.box.width - cw), height: whole(layout.box.height - lh))
        let path = NSBezierPath(roundedRect: frame, xRadius: cw * 0.7, yRadius: cw * 0.7)
        path.lineWidth = width
        content.accent.withAlphaComponent(0.62).setStroke()
        path.stroke()
        guard let label = layout.label else { return }
        // The label sits in the top edge: the line stops for it.
        let size = label.size()
        let origin = CGPoint(x: layout.labelOrigin.x, y: layout.labelOrigin.y + (lh - size.height) / 2)
        content.background.setFill()
        CGRect(x: origin.x, y: frame.minY - width * 2, width: ceil(size.width), height: width * 4).fill()
        label.draw(at: origin)
    }

    /// One line per agent: spinner, who, what, how long. Your turn: one still line, done and when.
    private func drawLines(_ layout: FocusLayout, _ content: FocusCoverContent) {
        let now = clock ?? Date().timeIntervalSince1970
        var rows: [(who: String, what: String, detail: String?, since: TimeInterval?)] = [
            ("claude", content.mainText, content.agents.isEmpty ? content.mainDetail : nil, content.turnStartedAt),
        ]
        for agent in content.agents {
            rows.append((Self.who(agent.kind), agent.label, agent.tool, agent.startedAt))
        }
        let limit = layout.maxLines
        // The task Claude is on, under its step, where there's a line to spare.
        var taskRow: Int?
        if let task = content.task, rows.count < limit {
            rows.insert(("task", task, nil, nil), at: 1)
            taskRow = 1
        }
        var extra = 0
        if rows.count > limit {
            extra = rows.count - (limit - 1)
            rows = Array(rows.prefix(max(0, limit - 1)))
        }
        let font = layout.cell
        let spinnerFont = NSFont.monospacedSystemFont(ofSize: (font.pointSize * 1.4).rounded(), weight: .bold)
        let bright = content.foreground.withAlphaComponent(0.9)
        let dim = content.foreground.withAlphaComponent(0.5)
        let faint = content.foreground.withAlphaComponent(0.34)
        let cw = layout.cellWidth
        let left = layout.lines.minX + cw
        let right = layout.lines.maxX - cw
        let whoX = left + cw * 2.5
        let whatX = whoX + cw * 10
        let baseline = ((layout.rowHeight - layout.lineHeight) / 2).rounded()
        for (index, row) in rows.enumerated() {
            let y = layout.lines.minY + CGFloat(index) * layout.rowHeight + baseline
            let glyph = content.yourTurn ? "✓" : index == taskRow ? "›" : still ? "•"
                : String(FocusLayout.spinner[(frameIndex + index * 3) % FocusLayout.spinner.count])
            let glyphSize = (glyph as NSString).size(withAttributes: [.font: spinnerFont])
            (glyph as NSString).draw(at: NSPoint(x: left, y: y + (layout.lineHeight - glyphSize.height) / 2),
                                     withAttributes: [.font: spinnerFont, .foregroundColor: content.accent])
            (row.who as NSString).draw(at: NSPoint(x: whoX, y: y), withAttributes: [.font: font, .foregroundColor: dim])
            var trailing = row.since.map { Self.elapsed(max(0, now - $0)) } ?? ""
            if let detail = row.detail, !detail.isEmpty { trailing = trailing.isEmpty ? detail : "\(detail)  \(trailing)" }
            if content.yourTurn {
                trailing = content.doneAt.flatMap { Fmt.ago($0 * 1000, now: Date(timeIntervalSince1970: now)) } ?? ""
            }
            let trailingWidth = (trailing as NSString).size(withAttributes: [.font: font]).width
            (trailing as NSString).draw(at: NSPoint(x: right - trailingWidth, y: y), withAttributes: [.font: font, .foregroundColor: faint])
            let whatWidth = right - trailingWidth - cw * 2 - whatX
            guard whatWidth > cw * 4 else { continue }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (row.what as NSString).draw(with: CGRect(x: whatX, y: y, width: whatWidth, height: layout.lineHeight),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: font, .foregroundColor: bright, .paragraphStyle: style])
        }
        if extra > 0 {
            let y = layout.lines.minY + CGFloat(rows.count) * layout.rowHeight + baseline
            ("+ \(extra) more running" as NSString).draw(at: NSPoint(x: whoX, y: y), withAttributes: [.font: font, .foregroundColor: dim])
        }
    }

    /// A subagent's type, as a short column: "explore", "agent", "code-rev…".
    static func who(_ kind: String?) -> String {
        guard let kind = kind?.lowercased(), !kind.isEmpty else { return "agent" }
        if kind.hasPrefix("general") { return "agent" }
        return kind.count > 8 ? String(kind.prefix(7)) + "…" : kind
    }

    /// "12s", "2m 05s", "1h 04m".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}

// MARK: - Window

/// Opaque where it draws, takes clicks (one opens the session), never key, never activates the
/// island: only ever ordered directly above a Terminal window.
final class FocusCoverWindow: NSPanel {
    let cover = FocusCoverView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        alphaValue = 0
        contentView = cover
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
