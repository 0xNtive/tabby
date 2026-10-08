import Foundation

// What a session is doing right now, and the gist of Claude's last reply, read from its
// transcript on this Mac (nothing is sent anywhere). Focus mode's cover shows both: the step
// under way while Claude works ("Editing tile.js"), and when it's done, the reply's opening and
// any question it ends on, so a finished window doesn't greet you with a wall of text.

// MARK: - The step under way

enum ActivityDescriber {
    /// A tool call as a short phrase: "Editing tile.js", "Run the test suite", "Searching for “tile”".
    static func describe(tool name: String, input: [String: Any]) -> String {
        func text(_ key: String) -> String? {
            guard let value = input[key] as? String else { return nil }
            let line = Fmt.oneLine(value, max: 80)
            return line.isEmpty ? nil : line
        }
        func file(_ key: String) -> String? {
            text(key).map { ($0 as NSString).lastPathComponent }
        }
        switch name {
        case "Bash":
            // Claude writes a description for most commands ("Run the test suite"): the clearest.
            if let description = text("description") { return description }
            return text("command").map { "$ " + Fmt.oneLine($0, max: 60) } ?? "Running a command"
        case "Read": return file("file_path").map { "Reading \($0)" } ?? "Reading a file"
        case "Edit", "MultiEdit": return file("file_path").map { "Editing \($0)" } ?? "Editing a file"
        case "Write": return file("file_path").map { "Writing \($0)" } ?? "Writing a file"
        case "NotebookEdit": return file("notebook_path").map { "Editing \($0)" } ?? "Editing a notebook"
        case "Grep": return text("pattern").map { "Searching for “\(Fmt.oneLine($0, max: 40))”" } ?? "Searching the code"
        case "Glob": return text("pattern").map { "Looking for \(Fmt.oneLine($0, max: 40))" } ?? "Looking for files"
        case "WebFetch":
            if let url = text("url"), let host = URL(string: url)?.host { return "Reading \(host)" }
            return "Reading a web page"
        case "WebSearch": return text("query").map { "Searching the web for “\(Fmt.oneLine($0, max: 40))”" } ?? "Searching the web"
        case "Agent", "Task":
            return text("description").map { "Delegating: \($0)" } ?? "Running a subagent"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet": return "Updating its task list"
        case "Skill": return text("skill").map { "Using the \($0) skill" } ?? "Using a skill"
        case "ToolSearch": return "Looking up tools"
        case "AskUserQuestion": return "Asking you a question"
        case "ExitPlanMode", "EnterPlanMode": return "Planning"
        default:
            // mcp__server__tool_name → "server: tool name"
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                if parts.count >= 2 {
                    let server = parts[0].replacingOccurrences(of: "claude_ai_", with: "")
                        .replacingOccurrences(of: "plugin_", with: "")
                        .replacingOccurrences(of: "_", with: " ")
                    let tool = parts[1...].joined(separator: " ").replacingOccurrences(of: "_", with: " ")
                    return "\(server): \(tool)"
                }
            }
            return "Using \(name)"
        }
    }
}

enum TranscriptActivity {
    /// What the main agent is doing in its current turn: the tool call still waiting for its
    /// result, else what it last wrote mid-turn, else "Thinking". Nil before the turn shows up.
    /// `lines`: the transcript's tail, oldest first.
    static func current<Lines: BidirectionalCollection>(_ lines: Lines) -> String? where Lines.Element: StringProtocol {
        var answered = Set<String>()
        for line in lines.reversed() {
            guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\""),
                  !line.contains("\"isSidechain\":true"),
                  let object = parse(line), let type = object["type"] as? String,
                  let message = object["message"] as? [String: Any] else { continue }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if type == "user" {
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                if results.isEmpty {
                    if object["isMeta"] as? Bool == true { continue }
                    return "Thinking"   // the prompt that started this turn: nothing done yet
                }
                for result in results { if let id = result["tool_use_id"] as? String { answered.insert(id) } }
                continue
            }
            let calls = blocks.filter { $0["type"] as? String == "tool_use" }
            if let pending = calls.last(where: { !answered.contains($0["id"] as? String ?? "") }),
               let name = pending["name"] as? String {
                return describe(pending, name: name)
            }
            if !calls.isEmpty { return "Thinking" }   // its results are in: deciding what's next
            // Text written mid-turn ("Checking the docs first:") says what it's about to do.
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let said = ReplySummary.clean(firstLine)
            if !said.isEmpty { return Fmt.oneLine(said.trimmingCharacters(in: CharacterSet(charactersIn: ":")), max: 100) }
            return "Thinking"
        }
        return nil
    }

    /// The reply that ended the last turn, condensed. Nil while a turn runs (a tool call is the
    /// last thing) or when the turn was interrupted.
    static func lastReply<Lines: BidirectionalCollection>(_ lines: Lines) -> ReplySummary? where Lines.Element: StringProtocol {
        var texts: [String] = []
        for line in lines.reversed() {
            guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\""),
                  !line.contains("\"isSidechain\":true"),
                  let object = parse(line), let type = object["type"] as? String,
                  let message = object["message"] as? [String: Any] else { continue }
            if type == "user" {
                if object["isMeta"] as? Bool == true { continue }
                break
            }
            if object["isApiErrorMessage"] as? Bool == true { return nil }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if blocks.contains(where: { $0["type"] as? String == "tool_use" }) { break }
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n\n")
            if !text.isEmpty { texts.insert(text, at: 0) }
        }
        let reply = texts.joined(separator: "\n\n")
        return reply.isEmpty ? nil : ReplySummary.make(reply)
    }

    private static func describe(_ block: [String: Any], name: String) -> String {
        ActivityDescriber.describe(tool: name, input: block["input"] as? [String: Any] ?? [:])
    }

    private static func parse<Line: StringProtocol>(_ line: Line) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

// MARK: - The reply, condensed

/// The gist of a reply: how it opens (Claude leads with what it did), and what it asks of you.
struct ReplySummary: Equatable, Sendable {
    /// The first plain paragraph, up to two sentences.
    var lead: String
    /// A question or request near the end ("Want me to ship 0.4.2?"), when there is one.
    var ask: String?
    /// How long the whole reply is, in lines.
    var lines: Int

    static func make(_ reply: String) -> ReplySummary? {
        let paragraphs = Self.paragraphs(reply)
        let prose = paragraphs.filter { $0.kind == .prose }.map(\.text)
        guard let first = prose.first ?? paragraphs.first(where: { $0.kind == .item })?.text else { return nil }
        let lead = shorten(sentences(first).prefix(2).joined(separator: " "), max: 260)
        var ask: String?
        for paragraph in prose.suffix(2).reversed() {
            let all = sentences(paragraph)
            if let question = all.last(where: { $0.hasSuffix("?") }) ?? all.last(where: isRequest) {
                ask = shorten(question, max: 160)
                break
            }
        }
        if let found = ask, lead.contains(found) || found.contains(lead) { ask = nil }
        let count = reply.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return ReplySummary(lead: lead, ask: ask, lines: count)
    }

    private enum Kind { case prose, item, other }

    /// Blank-line separated blocks, code blocks left out, markdown taken off.
    private static func paragraphs(_ reply: String) -> [(kind: Kind, text: String)] {
        var out: [(Kind, String)] = []
        var current: [String] = []
        var inCode = false
        func flush() {
            defer { current = [] }
            guard let head = current.first?.trimmingCharacters(in: .whitespaces) else { return }
            let kind: Kind
            if head.hasPrefix("#") || head.hasPrefix("|") || head.hasPrefix(">") {
                kind = .other
            } else if head.range(of: #"^([-*+•]|\d+[.)])\s"#, options: .regularExpression) != nil {
                // A list: its first item can stand in when there's no plain paragraph.
                out.append((.item, clean(head.replacingOccurrences(of: #"^([-*+•]|\d+[.)])\s+"#, with: "", options: .regularExpression))))
                return
            } else if head.range(of: #"^\*\*[^*]+\*\*:?$"#, options: .regularExpression) != nil, current.count == 1 {
                kind = .other   // a bold label on its own line
            } else {
                kind = .prose
            }
            let text = clean(current.joined(separator: " "))
            if !text.isEmpty { out.append((kind, text)) }
        }
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush()
                inCode.toggle()
                continue
            }
            if inCode { continue }
            if line.isEmpty {
                flush()
            } else if !current.isEmpty, line.range(of: #"^([-*+•]|\d+[.)])\s"#, options: .regularExpression) != nil,
                      current.first?.range(of: #"^([-*+•]|\d+[.)])\s"#, options: .regularExpression) == nil {
                // A list straight after a sentence ("…in these places:\n- …") starts a new block.
                flush()
                current = [line]
            } else {
                current.append(line)
            }
        }
        flush()
        return out
    }

    /// Markdown off: **bold**, *em*, `code`, [text](link), heading marks.
    static func clean(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, "$1"),
            (#"`([^`]+)`"#, "$1"),
            (#"^#+\s*"#, ""),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return Fmt.oneLine(s, max: 2000)
    }

    private static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        (text as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (text as NSString).length),
                                               options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { out.append(sentence) }
        }
        return out.isEmpty ? [text] : out
    }

    /// "Tell me when it's in…", "Let me know…", "Say the word…": asks without a question mark.
    private static func isRequest(_ sentence: String) -> Bool {
        sentence.range(of: #"^(Tell me|Let me know|Say the word|Reply with|Send me|Confirm|Please (confirm|check|try|run|tell))\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func shorten(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        let cut = text.prefix(max)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }
}
