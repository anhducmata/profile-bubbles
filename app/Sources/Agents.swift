// Agent bubbles: a row in the bottom-right corner, one bubble per coding agent that Orca runs
// (Claude Code, Codex, …). Click a bubble to jump to Orca and that agent's terminal tab. When an
// agent asks for an approval or a choice, a bar above the row shows the question and its options.
//
// Everything comes from the `orca` CLI: Orca already tracks each agent's state through its own
// agent hooks, so this app installs nothing into the agents.
import Cocoa

// MARK: - Model

struct AgentOption: Equatable {
    let number: Int
    let label: String
}

struct AgentPrompt: Equatable {
    let question: String
    let options: [AgentOption]
}

struct Agent: Equatable {
    let id: String          // Orca pane key, "<tab id>:<leaf id>"
    let kind: String        // "claude", "codex", ...
    let state: String       // working | blocked | waiting | done
    let workspace: String
    let title: String
    let handle: String?     // Orca terminal handle, needed to switch to it or answer
    var lastMessage = ""    // what the agent said last, shown in the hover card
    var prompt: AgentPrompt?
    // A Claude Code session outside Orca (see ClaudeHook.swift): no terminal to type into, so it
    // has no buttons; a click brings forward the app that holds it.
    var standalone = false
    var hostPid: pid_t = 0
    var hostName = ""

    var needsYou: Bool { state == "blocked" || state == "waiting" }
    var displayTitle: String { title.isEmpty ? workspace : title }

    var stateColor: NSColor {
        switch state {
        case "working": return .systemBlue
        case "blocked": return .systemOrange
        case "waiting": return .systemYellow
        case "done": return .systemGreen
        default: return .systemGray
        }
    }

    var stateText: String {
        switch state {
        case "working": return tr("working", "đang chạy")
        case "blocked": return tr("needs approval", "chờ duyệt")
        case "waiting": return tr("waiting for you", "chờ bạn trả lời")
        case "done": return tr("done", "xong")
        default: return state
        }
    }
}

// MARK: - Orca CLI

enum Orca {
    static let bundleID = "com.stablyai.orca"

    static let cliPath: String? = {
        let candidates = ["/Applications/Orca.app/Contents/Resources/bin/orca",
                          NSHomeDirectory() + "/Applications/Orca.app/Contents/Resources/bin/orca",
                          "/usr/local/bin/orca", "/opt/homebrew/bin/orca"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs `orca <args> --json` and returns its `result` object. Never call on the main thread.
    static func run(_ args: [String], timeout: TimeInterval = 6) -> [String: Any]? {
        guard let cli = cliPath else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cli)
        task.arguments = args + ["--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        task.environment = env
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["ok"] as? Bool == true else { return nil }
        return root["result"] as? [String: Any]
    }

    static func screen(of handle: String) -> [String] { read(handle).screen }

    /// The rendered screen, plus the text of the agent's input box when Orca reports it apart
    /// from the screen (`draft`, which it leaves out of the screen lines).
    static func read(_ handle: String) -> (screen: [String], draft: String) {
        let terminal = run(["terminal", "read", "--terminal", handle, "--screen"])?["terminal"] as? [String: Any]
        return (terminal?["tail"] as? [String] ?? [], (terminal?["draft"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the agent's input box holds: a draft or the next prompt it suggests. "" when the box
    /// is empty, nil when no box is on screen. `source` says where it was found, for the log.
    static func input(of handle: String) -> (screen: [String], text: String?, source: String) {
        let (screen, draft) = read(handle)
        if !draft.isEmpty { return (screen, draft, "draft") }
        let parsed = inputText(screen)
        return (screen, parsed, parsed == nil ? "none" : "screen")
    }

    static func activateApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?
            .activate(options: [.activateAllWindows])
    }
}

/// Finds a selection menu at the bottom of a terminal screen, the shape Claude Code and similar
/// agents draw for permission requests and questions:
///
///     Do you want to proceed?
///     ❯ 1. Yes
///       2. Yes, and don't ask again for …
///       3. No
///
/// A cursor (❯) on one of the numbered lines is required, so a numbered list in ordinary output
/// is not mistaken for a menu.
func parsePrompt(_ screen: [String]) -> AgentPrompt? {
    let lines = Array(screen.suffix(45))
    let frame = CharacterSet(charactersIn: "│┃|╭╮╰╯─━ \t")
    guard let regex = try? NSRegularExpression(pattern: "^\\s*([❯›>])?\\s*(\\d{1,2})\\.\\s+(\\S.*)$") else { return nil }

    var found: [(line: Int, cursor: Bool, option: AgentOption)] = []
    for (index, raw) in lines.enumerated() {
        let text = raw.trimmingCharacters(in: frame)
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let number = Int(ns.substring(with: m.range(at: 2))) else { continue }
        let label = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: frame)
        found.append((index, m.range(at: 1).location != NSNotFound, AgentOption(number: number, label: label)))
    }
    guard let start = found.lastIndex(where: { $0.option.number == 1 }) else { return nil }
    var run = [found[start]]
    for item in found[(start + 1)...] where item.option.number == run.count + 1 { run.append(item) }
    guard run.count >= 2, run.contains(where: { $0.cursor }) else { return nil }

    var question = ""
    for index in stride(from: run[0].line - 1, through: max(0, run[0].line - 6), by: -1) {
        let text = lines[index].trimmingCharacters(in: frame)
        if !text.isEmpty { question = text; break }
    }
    return AgentPrompt(question: question, options: run.map(\.option))
}

/// The text in the agent's input box (the `❯` line between two rules at the bottom of the screen):
/// a draft, or the next prompt the agent suggests. "" when the box is empty, nil when there is no box.
func inputText(_ screen: [String]) -> String? {
    let lines = Array(screen.suffix(14))
    for index in stride(from: lines.count - 1, through: 1, by: -1) {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("❯"), lines[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix("─") else { continue }
        var parts = [String(line.dropFirst()).trimmingCharacters(in: .whitespaces)]
        for next in lines[(index + 1)...] {
            let text = next.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("─") { break }
            parts.append(text)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
    return nil
}

/// What a working agent is doing right now: the last lines of its terminal above the input box
/// (its latest steps and the status line with the timer), for the hover card.
func activityText(_ screen: [String], lines limit: Int = 9, width: Int = 62) -> String {
    var rows = screen
    // Cut at the rule above the input box; what is below is the box and the mode line.
    if let box = rows.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }), box > 0,
       rows[box - 1].trimmingCharacters(in: .whitespaces).hasPrefix("─") {
        rows = Array(rows[..<(box - 1)])
    }
    let frame = CharacterSet(charactersIn: "│┃|╭╮╰╯─━ \t")
    let kept: [String] = rows.compactMap { raw in
        // Side panels are drawn to the right of a "│": keep the main column only.
        let main = raw.components(separatedBy: "│").first ?? raw
        let text = main.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        if text.trimmingCharacters(in: frame).isEmpty { return nil }
        return text.count > width ? String(text.prefix(width - 1)) + "…" : text
    }
    // Drop the shared left margin so the block sits flush in the card.
    let tail = Array(kept.suffix(limit))
    let margin = tail.map { $0.prefix { $0 == " " }.count }.min() ?? 0
    return tail.map { String($0.dropFirst(margin)) }.joined(separator: "\n")
}

/// What one click in the hover card does.
enum QuickAction {
    case option(AgentOption)   // press an option of the agent's menu
    case submitInput(String)   // press Enter on what the input box already shows
    case prompt(String)        // send a short prompt
    case interrupt             // Escape, while the agent is working
    case open                  // jump to the agent's tab
    case dismiss               // take a finished agent's bubble off the row
}

/// Prompts offered for an idle agent; edited in Settings.
var quickPrompts: [String] {
    let stored = UserDefaults.standard.stringArray(forKey: "agentQuickPrompts") ?? []
    return stored.isEmpty ? ["continue", "commit"] : stored
}

/// An agent's last message made quick to read in the hover card: markdown marks removed, and when
/// it is long, the opening paragraph and the closing one (where the question or next step usually
/// is) with "⋯" between. Cuts fall on sentence or word ends, never inside a word.
func readable(_ message: String, limit: Int = 700) -> String {
    func clean(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("#") { t.removeFirst() }
        if t.hasPrefix("- ") || t.hasPrefix("* ") { t = "• " + t.dropFirst(2) }
        for mark in ["**", "__", "`"] { t = t.replacingOccurrences(of: mark, with: "") }
        return t.trimmingCharacters(in: .whitespaces)
    }
    // Paragraphs: blank lines separate them; table rules and code fences are dropped.
    var paragraphs: [String] = []
    var current: [String] = []
    for raw in message.components(separatedBy: .newlines) {
        let line = clean(raw)
        let rule = !line.isEmpty && line.allSatisfy { "|-: ".contains($0) }
        if line.isEmpty { if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")); current = [] } }
        else if !rule { current.append(line) }
    }
    if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
    let whole = paragraphs.joined(separator: "\n\n")
    if whole.count <= limit { return whole }

    /// The first (or last) `count` characters, moved to the nearest sentence end, else word end.
    func cut(_ text: String, _ count: Int, fromEnd: Bool) -> String {
        if text.count <= count { return text }
        if fromEnd {
            let piece = String(text.suffix(count))
            if let r = piece.range(of: ". ") ?? piece.range(of: "\n") ?? piece.range(of: " ") {
                return "…" + piece[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "…" + piece
        }
        let piece = String(text.prefix(count))
        if let r = piece.range(of: ". ", options: .backwards) ?? piece.range(of: "\n", options: .backwards) {
            return String(piece[..<r.lowerBound]) + (piece[r].hasPrefix(".") ? "." : "") + " …"
        }
        if let r = piece.range(of: " ", options: .backwards) { return String(piece[..<r.lowerBound]) + " …" }
        return piece + "…"
    }
    let head = cut(paragraphs[0], limit * 2 / 5, fromEnd: false)
    // Closing paragraphs, as many as fit in the rest.
    var tail: [String] = []
    var room = limit - head.count
    for paragraph in paragraphs.dropFirst().reversed() {
        if paragraph.count <= room { tail.insert(paragraph, at: 0); room -= paragraph.count }
        else { if tail.isEmpty { tail = [cut(paragraph, room, fromEnd: true)] }; break }
    }
    if tail.isEmpty { return head }
    let skipped = tail.count < paragraphs.count - 1 || tail[0].hasPrefix("…")
    return head + (skipped && !tail[0].hasPrefix("…") ? "\n⋯\n" : "\n\n") + tail.joined(separator: "\n\n")
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Options that only open a text field cannot be answered with one click.
func needsTyping(_ label: String) -> Bool {
    let l = label.lowercased()
    return l.hasPrefix("type something") || l.hasPrefix("chat about this") || l.hasPrefix("other")
}

func shortLabel(_ label: String, limit: Int = 30) -> String {
    var text = label
    if let range = text.range(of: " (", options: .backwards), text.hasSuffix(")") { text = String(text[..<range.lowerBound]) }
    return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
}

// MARK: - Position

/// Where the agent row sits; set apart from the Chrome profile bubbles' position.
enum AgentPosition: String, CaseIterable {
    case bottomRight, bottomLeft, topRight, topLeft, leftOfNotch, rightOfNotch, rightEdge, leftEdge
    static let key = "agentPosition"
    static let badgesKey = "agentBadges"
    /// Long badges with the agent's title instead of round bubbles.
    static var badges: Bool { UserDefaults.standard.bool(forKey: badgesKey) }

    var title: String {
        switch self {
        case .bottomRight: return tr("Bottom right", "Góc dưới phải")
        case .bottomLeft: return tr("Bottom left", "Góc dưới trái")
        case .topRight: return tr("Top right, under the menu bar", "Góc trên phải, dưới thanh menu")
        case .topLeft: return tr("Top left, under the menu bar", "Góc trên trái, dưới thanh menu")
        case .leftOfNotch: return tr("Menu bar, left of the notch", "Thanh menu, bên trái tai thỏ")
        case .rightOfNotch: return tr("Menu bar, right of the notch", "Thanh menu, bên phải tai thỏ")
        case .rightEdge: return tr("Right edge", "Mép phải")
        case .leftEdge: return tr("Left edge", "Mép trái")
        }
    }
    var isColumn: Bool { self == .rightEdge || self == .leftEdge }
    var inMenuBar: Bool { self == .leftOfNotch || self == .rightOfNotch }
    /// Which way the row grows: from the right end (true) or the left end.
    var isRight: Bool { self == .bottomRight || self == .topRight || self == .rightEdge || self == .leftOfNotch }
    /// Bar and card open below the row.
    var isTop: Bool { self == .topRight || self == .topLeft || inMenuBar }

    static var current: AgentPosition {
        AgentPosition(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .bottomRight
    }
}

// MARK: - Views

/// A floating panel that can take the keyboard (for the reply box) without activating this app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

func makeFloatingPanel(takesKeyboard: Bool = false) -> NSPanel {
    let p = (takesKeyboard ? KeyPanel.self : NSPanel.self).init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = .statusBar
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    p.hidesOnDeactivate = false
    p.isFloatingPanel = true
    // After isFloatingPanel, which resets the level to .floating. Only a level above the menu
    // bar lets the panel sit in the menu bar strip (around the notch) instead of being pushed below it.
    p.level = .statusBar
    if takesKeyboard {
        p.becomesKeyOnlyIfNeeded = true
        p.appearance = NSAppearance(named: .darkAqua)
    }
    return p
}

/// The menu option that opens a text field ("Type something", "No, and tell Claude what to do
/// differently"): a typed reply goes through it.
func typingOption(_ prompt: AgentPrompt) -> AgentOption? {
    prompt.options.first { $0.label.lowercased().hasPrefix("type something") }
        ?? prompt.options.first { $0.label.lowercased().contains("tell claude") }
}

final class AgentBubbleView: NSView {
    let agent: Agent
    weak var controller: AgentsController?
    private var hovering = false { didSet { needsDisplay = true; updateSpinner() } }
    private var spinner: CAShapeLayer?
    private var spins: Bool { agent.state == "working" && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var ringInset: CGFloat { bounds.height * (hovering ? 0.06 : 0.115) }
    /// A long badge (round icon, then the title) when wider than tall.
    private var isBadge: Bool { bounds.width > bounds.height + 1 }
    /// The round part: the whole view for a bubble, its left end for a badge.
    private var circleRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.height, height: bounds.height).insetBy(dx: ringInset, dy: ringInset)
    }

    init(agent: Agent, size: CGFloat, width: CGFloat? = nil) {
        self.agent = agent
        super.init(frame: NSRect(x: 0, y: 0, width: width ?? size, height: size))
        wantsLayer = true
        toolTip = isBadge ? agent.displayTitle : nil
    }

    static func titleFont(height: CGFloat) -> NSFont { .systemFont(ofSize: min(13, max(11, height * 0.3)), weight: .medium) }

    /// Width of an agent's long badge: icon, title (cut at `maxWidth`), and room for the "!" mark.
    static func badgeWidth(for agent: Agent, height: CGFloat, maxWidth: CGFloat = 230) -> CGFloat {
        let text = (agent.displayTitle as NSString).size(withAttributes: [.font: titleFont(height: height)]).width
        let mark = agent.needsYou ? height * 0.55 : 0
        return min(maxWidth, ceil(height + 4 + text + 12 + mark))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSpinner()
    }

    /// Working agents get an arc that runs around the ring. Its angle comes from the clock, so it
    /// does not jump back to the top each time the row is rebuilt.
    private func updateSpinner() {
        guard spins, window != nil, let host = layer else { spinner?.removeFromSuperlayer(); spinner = nil; return }
        let arc = spinner ?? CAShapeLayer()
        if spinner == nil {
            arc.fillColor = nil
            arc.strokeColor = agent.stateColor.cgColor
            arc.lineCap = .round
            arc.strokeEnd = 0.3
            host.addSublayer(arc)
            spinner = arc
            let period: CFTimeInterval = 1.1
            let phase = -2 * Double.pi * (CACurrentMediaTime().truncatingRemainder(dividingBy: period) / period)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = phase
            spin.toValue = phase - 2 * Double.pi
            spin.duration = period
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            arc.add(spin, forKey: "spin")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.lineWidth = 2.5
        arc.path = CGPath(ellipseIn: circleRect.insetBy(dx: 1.25, dy: 1.25), transform: nil)
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = circleRect
        let circle = NSBezierPath(ovalIn: rect)

        if isBadge {
            // The pill behind the icon and the title; its outline carries the state colour.
            let pillRect = NSRect(x: rect.minX, y: rect.minY, width: bounds.width - rect.minX - 2, height: rect.height)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor(white: hovering ? 0.18 : 0.13, alpha: 0.96).setFill()
            pill.fill()
            NSGraphicsContext.restoreGraphicsState()
            agent.stateColor.withAlphaComponent(agent.needsYou ? 0.9 : 0.35).setStroke()
            pill.lineWidth = agent.needsYou ? 1.5 : 1
            pill.stroke()

            let mark = agent.needsYou ? rect.height * 0.55 : 0
            let font = AgentBubbleView.titleFont(height: bounds.height)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let title = NSAttributedString(string: agent.displayTitle, attributes: [
                .font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.92), .paragraphStyle: style])
            let textHeight = ceil(font.ascender - font.descender)
            title.draw(with: NSRect(x: rect.maxX + 4, y: rect.midY - textHeight / 2 - font.descender,
                                    width: pillRect.maxX - rect.maxX - 4 - 8 - mark, height: textHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor(white: 0.13, alpha: 1).setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        let letter = String(agent.displayTitle.prefix(1)).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: rect.height * 0.42, weight: .semibold),
            .foregroundColor: fallbackColor(agent.workspace + agent.id).blended(withFraction: 0.35, of: .white) ?? .white]
        let size = letter.size(withAttributes: attrs)
        letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)

        // The ring carries the state; a thicker one when the agent needs the user.
        // Under a spinning arc the full ring is only a faint track.
        agent.stateColor.withAlphaComponent(spins ? 0.25 : (agent.state == "done" ? 0.75 : 1)).setStroke()
        let width: CGFloat = agent.needsYou ? 3 : 2
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: width / 2, dy: width / 2))
        ring.lineWidth = width
        ring.stroke()

        if agent.needsYou {
            let d = isBadge ? rect.height * 0.55 : bounds.width * 0.3
            let badge = isBadge ? NSRect(x: bounds.maxX - 2 - rect.height * 0.2 - d, y: rect.midY - d / 2, width: d, height: d)
                                : NSRect(x: bounds.maxX - d - 1, y: bounds.maxY - d - 1, width: d, height: d)
            agent.stateColor.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let mark = (agent.state == "blocked" ? "!" : "?") as NSString
            let markAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: d * 0.75, weight: .bold), .foregroundColor: NSColor.black]
            let markSize = mark.size(withAttributes: markAttrs)
            mark.draw(at: NSPoint(x: badge.midX - markSize.width / 2, y: badge.midY - markSize.height / 2), withAttributes: markAttrs)
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; controller?.showCard(for: agent.id) }
    override func mouseExited(with event: NSEvent) { hovering = false }   // the card hides itself, see watchCard
    override func mouseUp(with event: NSEvent) { controller?.jump(to: agent) }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = AppDelegate.shared?.contextMenu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// A rounded, clickable piece of the approval bar.
final class PillView: NSView {
    var onClick: (() -> Void)?
    private let fill: NSColor
    private let hoverFill: NSColor
    private var hovering = false { didSet { layer?.backgroundColor = (hovering ? hoverFill : fill).cgColor } }

    init(frame: NSRect, fill: NSColor, hoverFill: NSColor, radius: CGFloat) {
        self.fill = fill
        self.hoverFill = hoverFill
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Controller

final class AgentsController: NSObject, NSTextFieldDelegate {
    static let shared = AgentsController()
    static let enabledKey = "agentBubbles"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static let soundKey = "agentSound"
    static var soundEnabled: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }

    static func playFinishedSound() { AgentSound.play(.finished) }
    /// A different sound for "needs approval" or "waiting for you", so the two can be told apart by ear.
    static func playNeedsYouSound() { AgentSound.play(.needsYou) }

    private let rowPanel = makeFloatingPanel()
    private let barPanel = makeFloatingPanel()
    private let cardPanel = makeFloatingPanel(takesKeyboard: true)
    private let replyField = NSTextField(string: "")
    /// True while the user is in the reply box: the card then stays put and is not redrawn.
    private var replying: Bool { cardPanel.isVisible && cardPanel.isKeyWindow }
    private var cardAgentID: String?
    private var cardInput: String??          // input box text of the hovered agent; nil until read
    private var cardTimer: Timer?
    private var cardTicks = 0
    private var bubbleFrames: [String: NSRect] = [:]   // screen frame of each agent's bubble
    /// Width the profile bubbles take on each side of the notch (set by the profile layout).
    static var profileNotchLeft: CGFloat = 0
    static var profileNotchRight: CGFloat = 0
    /// Whether the Chrome profile bubbles are on screen (the agent row then avoids them).
    var profilesShown: Bool { UserDefaults.standard.object(forKey: "profilesEnabled") as? Bool ?? true }
    private var lastInputNote = ""
    private var cardActivity = ""            // live terminal lines of the hovered working agent
    /// Finished agents the user took off the row. One comes back when it starts working again.
    private var dismissed = Set(UserDefaults.standard.stringArray(forKey: "agentDismissed") ?? [])
    private let queue = DispatchQueue(label: "agents.poll")
    private var agents: [Agent] = []
    private var polling = false
    private var timer: Timer?
    private var loggedMissingCLI = false

    private let gap: CGFloat = 4
    private let maxBubbles = 8
    /// Finished agents leave the row after this (defaults key `agentDoneMinutes`, 30 by default).
    private var doneLifetime: TimeInterval {
        let minutes = UserDefaults.standard.double(forKey: "agentDoneMinutes")
        return (minutes > 0 ? minutes : 30) * 60
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
        // Test hook: `--show-card <n>` opens the hover card of bubble n and pins it for 20 seconds.
        if let i = CommandLine.arguments.firstIndex(of: "--show-card"), i + 1 < CommandLine.arguments.count,
           let n = Int(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard self.agents.indices.contains(n) else { return }
                self.showCard(for: self.agents[n].id)
                self.cardTimer?.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.hideCard() }
            }
        }
    }

    // MARK: Polling

    func poll() {
        guard AgentsController.enabled else {
            if !agents.isEmpty { agents = []; layout() }
            return
        }
        guard !polling else { return }
        if Orca.cliPath == nil && !loggedMissingCLI { loggedMissingCLI = true; log("agents: orca CLI not found, no Orca agents") }
        polling = true
        let previous = agents
        let lifetime = doneLifetime
        let hidden = dismissed
        queue.async { [weak self] in
            guard let self = self else { return }
            // Orca could not be asked this time (timeout): keep its bubbles as they were.
            var fresh: [Agent]? = (self.fetchOrca() ?? previous.filter { !$0.standalone }) + loadClaudeSessions(doneLifetime: lifetime)
            let active = Set((fresh ?? []).filter { $0.state != "done" }.map(\.id))   // these lose their dismissal
            fresh = fresh.map { $0.filter { !($0.state == "done" && hidden.contains($0.id)) } }
            // Agents that need the user sit nearest the corner.
            let order = ["blocked": 0, "waiting": 1, "working": 2, "done": 3]
            fresh?.sort { (order[$0.state] ?? 4, $0.id) < (order[$1.state] ?? 4, $1.id) }
            fresh = fresh.map { Array($0.prefix(self.maxBubbles)) }
            DispatchQueue.main.async {
                self.polling = false
                if !self.dismissed.isDisjoint(with: active) {
                    self.dismissed.subtract(active)
                    UserDefaults.standard.set(Array(self.dismissed), forKey: "agentDismissed")
                }
                guard let fresh = fresh, fresh != self.agents else { return }
                // States and menu sizes only: titles and questions never reach the log.
                func summary(_ list: [Agent]) -> String {
                    list.map { $0.state + ($0.prompt.map { "+menu\($0.options.count)" } ?? "") }.joined(separator: ",")
                }
                let before = summary(self.agents)
                // An agent that was on the row and has now finished its turn.
                let finished = fresh.filter { new in
                    new.state == "done" && self.agents.contains { $0.id == new.id && $0.state != "done" }
                }
                // An agent that was on the row and now asks for an approval or an answer.
                let asking = fresh.filter { new in
                    new.needsYou && self.agents.contains { $0.id == new.id && !$0.needsYou }
                }
                if AgentsController.soundEnabled {
                    // Needing the user matters more than finishing when both happen in one poll.
                    if !asking.isEmpty {
                        AgentsController.playNeedsYouSound()
                        log("agents: needs-you sound (\(asking.count))")
                    } else if !finished.isEmpty {
                        AgentsController.playFinishedSound()
                        log("agents: finished sound (\(finished.count))")
                    }
                }
                self.agents = fresh
                let after = summary(fresh)
                if before != after { log("agents: \(fresh.count) bubble(s) [\(after)]") }
                self.layout()
            }
        }
    }

    /// nil when Orca could not be asked (not running, timeout): keep what is on screen.
    private func fetchOrca() -> [Agent]? {
        if Orca.cliPath == nil { return [] }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Orca.bundleID).isEmpty { return [] }
        guard let rows = Orca.run(["agent", "list"])?["agents"] as? [[String: Any]] else { return nil }
        let now = Date().timeIntervalSince1970 * 1000
        let visible = rows.filter { row in
            guard row["state"] as? String == "done" else { return true }
            return now - (row["updatedAt"] as? Double ?? 0) < doneLifetime * 1000
        }
        if visible.isEmpty { return [] }

        var handles: [String: String] = [:]
        for t in Orca.run(["terminal", "list"])?["terminals"] as? [[String: Any]] ?? [] {
            guard let tab = t["tabId"] as? String, let leaf = t["leafId"] as? String,
                  let handle = t["handle"] as? String else { continue }
            handles["\(tab):\(leaf)"] = handle
        }

        var result: [Agent] = visible.compactMap { row in
            guard let pane = row["paneKey"] as? String else { return nil }
            return Agent(id: pane, kind: row["agent"] as? String ?? "agent", state: row["state"] as? String ?? "",
                         workspace: row["workspace"] as? String ?? "", title: row["title"] as? String ?? "",
                         handle: handles[pane], lastMessage: row["lastAssistantMessage"] as? String ?? "", prompt: nil)
        }
        for index in result.indices where result[index].needsYou {
            if let handle = result[index].handle { result[index].prompt = parsePrompt(Orca.screen(of: handle)) }
        }
        return result
    }

    // MARK: Layout

    func layout() {
        guard AgentsController.enabled, !agents.isEmpty, let screen = NSScreen.screens.first ?? NSScreen.main else {
            rowPanel.orderOut(nil)
            barPanel.orderOut(nil)
            hideCard()
            return
        }
        let position = AgentPosition.current
        let profiles = Position.current
        let full = screen.frame, visible = screen.visibleFrame
        // In the menu bar the bubbles are as tall as the bar, like the profile bubbles at the notch.
        let menuBar = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : full.maxY - visible.maxY
        let size = position.inMenuBar ? menuBar : preferredBubbleSize
        let widths = agents.map { AgentPosition.badges ? AgentBubbleView.badgeWidth(for: $0, height: size) : size }
        let total = widths.reduce(0, +)
        var frame: NSRect
        switch position {
        case .rightEdge, .leftEdge:
            // Next to the profile column when both use the same edge.
            let shared = profilesShown && profiles == (position.isRight ? .right : .left)
            let inset = gap + (shared ? preferredBubbleSize + gap : 0)
            let width = widths.max() ?? size
            let height = CGFloat(agents.count) * size
            let x = position.isRight ? visible.maxX - inset - width : visible.minX + inset
            frame = NSRect(x: x, y: visible.midY - height / 2, width: width, height: height)
        case .leftOfNotch, .rightOfNotch:
            // Against the notch, or beyond the profile bubbles when they are at the notch too.
            let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
            let notchLeft = left?.maxX ?? full.midX - 1, notchRight = right?.minX ?? full.midX + 1
            let taken = profilesShown && profiles.inMenuBar
                ? (position == .leftOfNotch ? AgentsController.profileNotchLeft : AgentsController.profileNotchRight) : 0
            let x = position == .leftOfNotch ? notchLeft - taken - total : notchRight + taken
            frame = NSRect(x: x, y: full.maxY - size, width: total, height: size)
        case .topRight, .topLeft:
            frame = NSRect(x: position.isRight ? full.maxX - gap - total : full.minX + gap,
                           y: visible.maxY - gap - size, width: total, height: size)
        case .bottomRight, .bottomLeft:
            // Above the profile bubbles when they use the same corner.
            let shared = profilesShown && profiles == (position.isRight ? .bottomRight : .bottomLeft)
            frame = NSRect(x: position.isRight ? full.maxX - gap - total : full.minX + gap,
                           y: full.minY + gap + (shared ? preferredBubbleSize + gap : 0), width: total, height: size)
        }
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        bubbleFrames = [:]
        var offset: CGFloat = 0
        for (index, agent) in agents.enumerated() {
            let bubble = AgentBubbleView(agent: agent, size: size, width: widths[index])
            bubble.controller = self
            // The first agent (the one most likely to need you) sits in the corner, next to the
            // notch, or at the top of a column.
            let w = widths[index]
            let origin: NSPoint
            if position.isColumn {
                origin = NSPoint(x: position.isRight ? frame.width - w : 0, y: frame.height - CGFloat(index + 1) * size)
            } else {
                origin = NSPoint(x: position.isRight ? frame.width - offset - w : offset, y: 0)
                offset += w
            }
            bubble.setFrameOrigin(origin)
            content.addSubview(bubble)
            bubbleFrames[agent.id] = NSRect(origin: NSPoint(x: frame.minX + origin.x, y: frame.minY + origin.y), size: bubble.frame.size)
        }
        rowPanel.contentView = content
        rowPanel.setFrame(frame, display: true)
        rowPanel.orderFrontRegardless()
        layoutBar(beside: frame, screen: screen)
        if cardAgentID != nil && !replying { renderCard() }   // keep an open card in step with the new state
    }

    private func pill(_ text: String, accent: Bool = false, tooltip: String? = nil, action: @escaping () -> Void) -> PillView {
        let label = field(text, weight: .medium, alpha: 1, maxWidth: 240)
        let button = PillView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 18, height: 24),
                              fill: accent ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.16),
                              hoverFill: NSColor.controlAccentColor, radius: 12)
        label.setFrameOrigin(NSPoint(x: 9, y: (24 - label.frame.height) / 2))
        button.addSubview(label)
        button.toolTip = tooltip
        button.onClick = action
        return button
    }

    private func field(_ text: String, weight: NSFont.Weight, alpha: CGFloat, maxWidth: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 12, weight: weight)
        f.textColor = NSColor.white.withAlphaComponent(alpha)
        f.lineBreakMode = .byTruncatingTail
        f.sizeToFit()
        f.frame.size.width = min(f.frame.width, maxWidth)
        return f
    }

    /// One bar per agent that needs the user: title, question, then a button per option.
    private func layoutBar(beside row: NSRect, screen: NSScreen) {
        let waiting = agents.filter(\.needsYou)
        guard !waiting.isEmpty else { barPanel.orderOut(nil); return }
        let rowHeight: CGFloat = 34
        var bars: [NSView] = []
        for agent in waiting {
            let bar = PillView(frame: .zero, fill: NSColor(white: 0.1, alpha: 0.94), hoverFill: NSColor(white: 0.16, alpha: 0.96), radius: rowHeight / 2)
            bar.onClick = { [weak self] in self?.jump(to: agent) }
            var x: CGFloat = 12
            func place(_ view: NSView, spacing: CGFloat) {
                view.setFrameOrigin(NSPoint(x: x, y: (rowHeight - view.frame.height) / 2))
                bar.addSubview(view)
                x += view.frame.width + spacing
            }
            let dot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = agent.stateColor.cgColor
            dot.layer?.cornerRadius = 4
            place(dot, spacing: 8)
            place(field(agent.displayTitle, weight: .semibold, alpha: 1, maxWidth: 170), spacing: 8)
            let question = agent.prompt?.question.isEmpty == false ? agent.prompt!.question : agent.stateText
            place(field(question, weight: .regular, alpha: 0.72, maxWidth: 260), spacing: 10)

            for option in (agent.prompt?.options ?? []).filter({ !needsTyping($0.label) }).prefix(4) {
                place(pill(shortLabel(option.label), tooltip: option.label) { [weak self] in self?.answer(agent, option: option) }, spacing: 6)
            }
            bar.frame = NSRect(x: 0, y: 0, width: x + 4, height: rowHeight)
            bars.append(bar)
        }
        let position = AgentPosition.current
        let full = screen.frame
        // A column has its bars beside it; a row has them above (bottom) or below (top).
        let limit = position.isColumn ? (position.isRight ? row.minX - gap - full.minX - gap : full.maxX - gap - row.maxX - gap)
                                      : full.width - gap * 2
        let width = min(bars.map(\.frame.width).max() ?? 0, limit)
        let height = CGFloat(bars.count) * (rowHeight + gap) - gap
        // The first bar sits nearest the row.
        let growsDown = position.isTop || position.isColumn
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        for (index, bar) in bars.enumerated() {
            bar.frame.size.width = min(bar.frame.width, limit)
            let y = growsDown ? height - CGFloat(index + 1) * rowHeight - CGFloat(index) * gap : CGFloat(index) * (rowHeight + gap)
            bar.setFrameOrigin(NSPoint(x: position.isRight ? width - bar.frame.width : 0, y: y))
            content.addSubview(bar)
        }
        var x: CGFloat, y: CGFloat
        if position.isColumn {
            x = position.isRight ? row.minX - gap - width : row.maxX + gap
            y = row.maxY - height
        } else {
            x = position.isRight ? full.maxX - gap - width : full.minX + gap
            y = position.isTop ? row.minY - gap - height : row.maxY + gap
        }
        y = min(max(y, full.minY + gap), full.maxY - gap - height)
        barPanel.contentView = content
        barPanel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        barPanel.orderFrontRegardless()
    }

    // MARK: Actions

    /// Bring Orca forward on the agent's terminal tab.
    func jump(to agent: Agent) {
        if agent.standalone {
            let host = NSRunningApplication(processIdentifier: agent.hostPid)
            log("agents: jump to standalone claude (\(agent.state)), host app \(host == nil ? "not found" : "found")")
            host?.activate(options: [.activateAllWindows])
            return
        }
        log("agents: jump to \(agent.kind) (\(agent.state))\(agent.handle == nil ? ", no terminal handle" : "")")
        Orca.activateApp()
        guard let handle = agent.handle else { return }
        queue.async {
            if Orca.run(["terminal", "switch", "--terminal", handle]) == nil { log("agents: terminal switch failed") }
            DispatchQueue.main.async { Orca.activateApp() }
        }
    }

    /// Press one option of the agent's menu. The screen is read again first, and the key is sent
    /// only when the same menu with the same option is still showing; otherwise jump to the tab.
    func answer(_ agent: Agent, option: AgentOption) {
        guard let handle = agent.handle else { jump(to: agent); return }
        queue.async { [weak self] in
            let current = parsePrompt(Orca.screen(of: handle))
            guard let current = current, current == agent.prompt, current.options.contains(option) else {
                log("agents: menu changed before answering, jumping instead")
                DispatchQueue.main.async { self?.jump(to: agent) }
                return
            }
            let sent = Orca.run(["terminal", "send", "--terminal", handle, "--text", String(option.number)]) != nil
            log("agents: answered option \(option.number) of \(current.options.count): \(sent ? "sent" : "send failed")")
            if sent {
                // Most menus act on the digit alone; one that only moved its cursor needs Enter.
                Thread.sleep(forTimeInterval: 0.6)
                if let after = parsePrompt(Orca.screen(of: handle)), after == current {
                    _ = Orca.run(["terminal", "send", "--terminal", handle, "--enter"])
                    log("agents: menu still open, sent Enter")
                }
            }
            DispatchQueue.main.async { self?.poll() }
        }
    }

    // MARK: Quick actions

    /// The suggested next actions for an agent, most likely first. Opening the tab is a click on
    /// the bubble or on the card itself, so it has no button.
    private func actions(for agent: Agent) -> [(title: String, tooltip: String?, action: QuickAction)] {
        var list: [(String, String?, QuickAction)] = []
        if agent.handle == nil {
            // Nothing can be typed into it from here.
        } else if let prompt = agent.prompt {
            for option in prompt.options.filter({ !needsTyping($0.label) }).prefix(4) {
                list.append((shortLabel(option.label), option.label, .option(option)))
            }
        } else if agent.state == "working" {
            list.append((tr("Interrupt", "Dừng lại"), nil, .interrupt))
        } else if case .some(.some(let input)) = cardInput {
            if input.isEmpty {
                for text in quickPrompts { list.append((shortLabel(text), text, .prompt(text))) }
            } else {
                // A draft or the agent's own suggested next prompt: Enter sends it.
                list.append(("↵ " + shortLabel(input, limit: 44), input, .submitInput(input)))
            }
        }
        if agent.state == "done" {
            list.append(("✕ " + tr("Remove", "Bỏ"), tr("Take this bubble off the row until the agent works again",
                                                       "Bỏ bong bóng này khỏi hàng cho tới khi agent chạy lại"), .dismiss))
        }
        return list.map { (title: $0.0, tooltip: $0.1, action: $0.2) }
    }

    /// Every action reads the screen again first and acts only when it still shows what the card
    /// showed; otherwise it jumps to the tab so the user can look.
    func perform(_ action: QuickAction, on agent: Agent) {
        hideCard()
        if case .dismiss = action {
            dismissed.insert(agent.id)
            if dismissed.count > 200 { dismissed = [agent.id] }   // ids of long-gone agents
            UserDefaults.standard.set(Array(dismissed), forKey: "agentDismissed")
            agents.removeAll { $0.id == agent.id }
            log("agents: bubble removed by the user")
            layout()
            return
        }
        guard let handle = agent.handle else { jump(to: agent); return }
        switch action {
        case .open, .dismiss: jump(to: agent)
        case .option(let option): answer(agent, option: option)
        case .submitInput, .prompt, .interrupt:
            queue.async { [weak self] in
                let screen = Orca.screen(of: handle)
                let found = Orca.input(of: handle)
                let box = found.text
                var args: [String]?
                var name = ""
                switch action {
                case .submitInput(let shown):
                    name = "submit input"
                    if box == shown, parsePrompt(screen) == nil {
                        // Text Orca reports as `draft` lives in Orca's own composer, not in the
                        // terminal, so Enter alone would submit nothing: type it as well.
                        if found.source == "draft" {
                            if inputText(found.screen) == "" { args = ["--text", shown, "--enter"] }
                        } else {
                            args = ["--enter"]
                        }
                    }
                case .prompt(let text):
                    name = "quick prompt"
                    if box == "", parsePrompt(screen) == nil { args = ["--text", text, "--enter"] }
                case .interrupt:
                    name = "interrupt"
                    if screen.suffix(4).contains(where: { $0.contains("esc to interrupt") }) { args = ["--text", "\u{1b}"] }
                default: break
                }
                guard let send = args else {
                    log("agents: \(name) skipped, the screen changed; jumping instead")
                    DispatchQueue.main.async { self?.jump(to: agent) }
                    return
                }
                let ok = Orca.run(["terminal", "send", "--terminal", handle] + send) != nil
                log("agents: \(name): \(ok ? "sent" : "send failed")")
                DispatchQueue.main.async { self?.poll() }
            }
        }
    }

    // MARK: Hover card

    private func bubbleRect(_ id: String) -> NSRect? {
        rowPanel.isVisible ? bubbleFrames[id] : nil
    }

    func showCard(for id: String) {
        guard cardAgentID != id, !(replying && !replyField.stringValue.isEmpty) else { return }
        replyField.stringValue = ""
        cardAgentID = id
        cardInput = nil
        renderCard()
        cardTicks = 0
        lastInputNote = ""
        cardActivity = ""
        refreshCardInput()
        cardTimer?.invalidate()
        cardTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.watchCard() }
    }

    /// The card stays while the pointer is over it or its bubble. Checked by position, since the
    /// bubble views are rebuilt on every state change and would lose their exit events.
    /// Reads the hovered agent's input box. Called when the card opens and every 1.5 s while it
    /// stays open, because the agent's suggested next prompt appears a few seconds after it finishes.
    private func refreshCardInput() {
        guard let id = cardAgentID, let agent = agents.first(where: { $0.id == id }), let handle = agent.handle,
              agent.prompt == nil else { return }
        if agent.state == "working" {
            // Show what it is doing, refreshed while the card stays open.
            queue.async { [weak self] in
                let activity = activityText(Orca.screen(of: handle))
                DispatchQueue.main.async {
                    guard let self = self, self.cardAgentID == id, activity != self.cardActivity else { return }
                    self.cardActivity = activity
                    if !self.replying { self.renderCard() }
                }
            }
            return
        }
        queue.async { [weak self] in
            let found = Orca.input(of: handle)
            DispatchQueue.main.async {
                guard let self = self, self.cardAgentID == id else { return }
                let note = "\(found.source) \(found.text?.count ?? 0) chars"   // never the text itself
                if note != self.lastInputNote { self.lastInputNote = note; log("agents: input box: \(note)") }
                if case .some(let old) = self.cardInput, old == found.text { return }
                self.cardInput = .some(found.text)
                if !self.replying { self.renderCard() }
            }
        }
    }

    private func watchCard() {
        guard let id = cardAgentID, let bubble = bubbleRect(id) else { hideCard(); return }
        cardTicks += 1
        if cardTicks % 8 == 0 { refreshCardInput() }
        if replying { return }   // typing a reply: Escape, sending, or a click elsewhere ends it
        let mouse = NSEvent.mouseLocation
        if !bubble.insetBy(dx: -2, dy: -2).contains(mouse) && !cardPanel.frame.insetBy(dx: -4, dy: -4).contains(mouse) { hideCard() }
    }

    func hideCard() {
        cardTimer?.invalidate()
        cardTimer = nil
        cardAgentID = nil
        replyField.stringValue = ""
        cardPanel.orderOut(nil)
    }

    // MARK: Reply box

    /// Whether a typed reply can be delivered in the agent's current state, and what the box says.
    private func replyPlaceholder(for agent: Agent) -> String? {
        guard agent.handle != nil else { return nil }
        if let prompt = agent.prompt {
            guard let option = typingOption(prompt) else { return nil }
            return option.label.lowercased().contains("tell claude")
                ? tr("Say what to do instead, Return to send", "Nói cần làm gì khác, Return để gửi")
                : tr("Type your own answer, Return to send", "Gõ câu trả lời riêng, Return để gửi")
        }
        return agent.state == "working" ? tr("Message (queued while it works), Return to send", "Nhắn (xếp hàng khi đang chạy), Return để gửi")
                                        : tr("Reply, Return to send", "Trả lời, Return để gửi")
    }

    @objc private func sendReply() {
        let text = replyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = cardAgentID, let agent = agents.first(where: { $0.id == id }),
              let handle = agent.handle else { return }
        hideCard()
        queue.async { [weak self] in
            let screen = Orca.screen(of: handle)
            func send(_ args: [String]) -> Bool { Orca.run(["terminal", "send", "--terminal", handle] + args) != nil }
            var outcome = "skipped, the screen changed; jumping instead"
            if let prompt = parsePrompt(screen) {
                // A menu is open: choose its typing option, then type. Orca refuses text plus
                // Enter in one go while a menu shows, so they are sent separately.
                if prompt == agent.prompt, let option = typingOption(prompt) {
                    var ok = send(["--text", String(option.number)])
                    Thread.sleep(forTimeInterval: 0.5)
                    ok = ok && send(["--text", text])
                    Thread.sleep(forTimeInterval: 0.3)
                    ok = ok && send(["--enter"])
                    outcome = ok ? "sent through menu option \(option.number)" : "send failed"
                }
            } else if inputText(screen) == "" {
                // Only the terminal's own input box has to be empty. A prompt the agent suggests
                // sits in Orca's composer, not in the terminal, so it is not in the way.
                outcome = send(["--text", text, "--enter"]) ? "sent" : "send failed"
            }
            log("agents: reply (\(text.count) chars): \(outcome)")
            DispatchQueue.main.async {
                if outcome.hasPrefix("skipped") {
                    // Do not lose what was typed: it goes to the clipboard before the jump.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self?.jump(to: agent)
                }
                self?.poll()
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { hideCard(); return true }
        return false
    }

    private func renderCard() {
        guard let id = cardAgentID, let agent = agents.first(where: { $0.id == id }), let bubble = bubbleRect(id) else { hideCard(); return }
        let width: CGFloat = 440, pad: CGFloat = 14, inner = width - pad * 2
        let content = FlippedView()
        var y = pad
        func add(_ view: NSView, gap: CGFloat) {
            view.setFrameOrigin(NSPoint(x: pad, y: y))
            content.addSubview(view)
            y += view.frame.height + gap
        }
        add(field(agent.displayTitle, weight: .semibold, alpha: 1, maxWidth: inner), gap: 2)
        let place = agent.workspace.isEmpty || agent.workspace == agent.displayTitle ? "" : "\(agent.workspace) · "
        let kind = agent.hostName.isEmpty ? agent.kind : "\(agent.kind) in \(agent.hostName)"
        let sub = field("\(place)\(kind) · \(agent.stateText)", weight: .regular, alpha: 0.6, maxWidth: inner)
        sub.textColor = agent.stateColor.blended(withFraction: 0.3, of: .white)
        add(sub, gap: 8)

        let live = agent.state == "working" && agent.prompt == nil && !cardActivity.isEmpty
        let body = agent.prompt?.question.isEmpty == false ? agent.prompt!.question
            : live ? cardActivity : readable(agent.lastMessage)
        if !body.isEmpty {
            let text = NSTextField(wrappingLabelWithString: body)
            text.font = live ? .monospacedSystemFont(ofSize: 10.5, weight: .regular) : .systemFont(ofSize: 12.5)
            text.textColor = NSColor.white.withAlphaComponent(0.88)
            text.maximumNumberOfLines = 0
            text.isSelectable = false
            text.preferredMaxLayoutWidth = inner
            let height = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10_000)).height ?? 16
            text.frame.size = NSSize(width: inner, height: ceil(height))
            add(text, gap: 12)
        }

        if let placeholder = replyPlaceholder(for: agent) {
            let box = NSView(frame: NSRect(x: 0, y: 0, width: inner, height: 30))
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            box.layer?.cornerRadius = 8
            replyField.removeFromSuperview()
            replyField.placeholderString = placeholder
            replyField.font = .systemFont(ofSize: 12.5)
            replyField.isBordered = false
            replyField.drawsBackground = false
            replyField.focusRingType = .none
            replyField.textColor = .white
            replyField.lineBreakMode = .byTruncatingHead
            replyField.cell?.usesSingleLineMode = true
            (replyField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false   // only Return sends
            replyField.target = self
            replyField.action = #selector(sendReply)
            replyField.delegate = self
            replyField.frame = NSRect(x: 8, y: 6, width: inner - 16, height: 18)
            box.addSubview(replyField)
            add(box, gap: 10)
        }

        // Buttons flow onto as many lines as they need.
        var x = pad
        var lineHeight: CGFloat = 0
        let list = actions(for: agent)
        for (index, item) in list.enumerated() {
            var accent = index == 0 && agent.state != "working"
            if case .dismiss = item.action { accent = false }
            let button = pill(item.title, accent: accent, tooltip: item.tooltip) { [weak self] in
                self?.perform(item.action, on: agent)
            }
            if x > pad && x + button.frame.width > width - pad { x = pad; y += lineHeight + 6 }
            button.setFrameOrigin(NSPoint(x: x, y: y))
            content.addSubview(button)
            x += button.frame.width + 6
            lineHeight = button.frame.height
        }
        y += list.isEmpty ? pad - 10 : lineHeight + pad

        let card = PillView(frame: NSRect(x: 0, y: 0, width: width, height: y),
                            fill: NSColor(white: 0.1, alpha: 0.96), hoverFill: NSColor(white: 0.1, alpha: 0.96), radius: 12)
        content.frame = card.bounds
        card.addSubview(content)
        card.onClick = { [weak self] in self?.perform(.open, on: agent) }
        // Touching the bubble, on the side away from the screen edge, so the pointer can move
        // from the bubble onto the card. It covers the approval bar while it is open.
        let position = AgentPosition.current
        var origin: NSPoint
        if position.isColumn {
            origin = NSPoint(x: position.isRight ? bubble.minX - width : bubble.maxX, y: bubble.maxY - y)
        } else {
            origin = NSPoint(x: position.isRight ? bubble.maxX - width : bubble.minX,
                             y: position.isTop ? bubble.minY - y : bubble.maxY)
        }
        if let bounds = rowPanel.screen?.frame ?? NSScreen.screens.first?.frame {
            origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - 4 - width)
            origin.y = min(max(origin.y, bounds.minY + 4), bounds.maxY - 4 - y)
        }
        cardPanel.contentView = card
        cardPanel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: y)), display: true)
        cardPanel.orderFrontRegardless()
    }
}
