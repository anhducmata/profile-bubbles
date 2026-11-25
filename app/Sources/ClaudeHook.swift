// Claude Code sessions that run outside Orca (Terminal, iTerm, an editor's terminal, the Claude
// desktop app). Orca reports its own agents; for the rest, Claude Code hooks run this same binary
// with `--claude-hook`, which writes the session's state to a small file the app reads.
//
// The hooks are added to ~/.claude/settings.json by scripts/claude-hooks.py (Settings checkbox).
// They do nothing inside Orca, where ORCA_AGENT_HOOK_PORT is set, so no agent shows twice.
import Cocoa

let claudeStateDir = configDir + "/claude"

private func processInfo(_ pid: pid_t) -> (parent: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
    }
    return (info.kp_eproc.e_ppid, name)
}

func processAlive(_ pid: pid_t) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

/// The text of the last assistant message in a Claude Code transcript (JSON lines).
private func lastAssistantText(transcript path: String) -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 262_144 ? size - 262_144 : 0)
    let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    for line in text.split(separator: "\n").reversed() {
        guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              row["type"] as? String == "assistant",
              let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
        let parts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        if !parts.isEmpty { return parts.joined(separator: "\n") }
    }
    return ""
}

/// Runs as a Claude Code hook: reads the event on stdin, updates the session's state file, prints
/// nothing (hook output could otherwise reach the agent) and never fails the hook.
func runClaudeHook() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let session = event["session_id"] as? String, !session.isEmpty,
          session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
          let name = event["hook_event_name"] as? String else { return }
    let path = "\(claudeStateDir)/\(session).json"
    if name == "SessionEnd" { try? FileManager.default.removeItem(atPath: path); return }

    var state = (FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
    let input2 = event["tool_input"] as? [String: Any] ?? [:]
    let tool = event["tool_name"] as? String ?? ""
    func set(_ value: String, question: String = "") { state["state"] = value; state["question"] = question }

    switch name {
    case "SessionStart":
        if state["state"] == nil { set("done") }   // also fires on resume and compaction: keep the state then
    case "UserPromptSubmit":
        set("working")
        if (state["title"] as? String ?? "").isEmpty, let prompt = event["prompt"] as? String {
            let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            state["title"] = String(line.prefix(80))
        }
    case "PreToolUse":   // installed only for the tools that ask the user something
        if tool == "AskUserQuestion" {
            let first = (input2["questions"] as? [[String: Any]])?.first
            set("waiting", question: first?["question"] as? String ?? "")
        } else if tool == "ExitPlanMode" {
            set("waiting", question: "Plan ready for review")
        } else { return }
    case "PermissionRequest":
        let detail = input2["command"] as? String ?? input2["file_path"] as? String ?? input2["url"] as? String ?? ""
        set("blocked", question: String("\(tool): \(detail)".prefix(300)))
    case "PostToolUse", "PostToolUseFailure":
        if state["state"] as? String == "working" { return }   // nothing new: skip the write
        set("working")
    case "Stop", "StopFailure":
        set("done")
        var message = event["last_assistant_message"] as? String ?? ""
        if message.isEmpty, let transcript = event["transcript_path"] as? String { message = lastAssistantText(transcript: transcript) }
        state["message"] = String(message.prefix(6000))
    default:
        return
    }

    // Who runs this session: the Claude process (to know when it is gone) and the app whose
    // window holds it (to bring forward on a click). Looked up once per Claude process.
    var chain: [(pid: pid_t, name: String)] = []
    var pid = getppid()
    while pid > 1, chain.count < 16, let info = processInfo(pid) {
        chain.append((pid, info.name))
        pid = info.parent
    }
    let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash"]
    let claudePid = chain.first { !shells.contains($0.name.replacingOccurrences(of: "-", with: "")) }?.pid ?? 0
    if state["claudePid"] as? Int != Int(claudePid) || state["hostPid"] == nil {
        state["claudePid"] = Int(claudePid)
        let host = chain.lazy.compactMap { NSRunningApplication(processIdentifier: $0.pid) }.first { $0.activationPolicy == .regular }
        state["hostPid"] = Int(host?.processIdentifier ?? 0)
        state["hostName"] = host?.localizedName ?? ""
    }
    state["session"] = session
    state["cwd"] = event["cwd"] as? String ?? state["cwd"] ?? ""
    state["updatedAt"] = Date().timeIntervalSince1970 * 1000

    try? FileManager.default.createDirectory(atPath: claudeStateDir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: state) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// The standalone Claude Code sessions to show. Files of sessions whose process is gone are removed.
func loadClaudeSessions(doneLifetime: TimeInterval) -> [Agent] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: claudeStateDir)) ?? []
    let now = Date().timeIntervalSince1970 * 1000
    var result: [Agent] = []
    for file in files where file.hasSuffix(".json") {
        let path = "\(claudeStateDir)/\(file)"
        guard let data = FileManager.default.contents(atPath: path),
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let session = row["session"] as? String, let state = row["state"] as? String else { continue }
        let updated = row["updatedAt"] as? Double ?? 0
        let claudePid = pid_t(row["claudePid"] as? Int ?? 0)
        // No known process: trust the file for half a day, then drop it.
        if claudePid > 0 ? !processAlive(claudePid) : now - updated > 12 * 3600 * 1000 {
            try? FileManager.default.removeItem(atPath: path)
            continue
        }
        if state == "done" && now - updated > doneLifetime * 1000 { continue }
        let cwd = row["cwd"] as? String ?? ""
        let question = row["question"] as? String ?? ""
        var agent = Agent(id: "claude:\(session)", kind: "claude", state: state,
                          workspace: (cwd as NSString).lastPathComponent, title: row["title"] as? String ?? "",
                          handle: nil, lastMessage: row["message"] as? String ?? "",
                          prompt: question.isEmpty ? nil : AgentPrompt(question: question, options: []))
        agent.standalone = true
        agent.hostPid = pid_t(row["hostPid"] as? Int ?? 0)
        agent.hostName = row["hostName"] as? String ?? ""
        result.append(agent)
    }
    return result
}

// MARK: - Installing the hooks

let claudeHooksScript = Bundle.main.resourcePath.map { $0 + "/claude-hooks.py" } ?? ""

/// Runs scripts/claude-hooks.py (install | uninstall | status). Returns its one-line answer.
@discardableResult
func claudeHooks(_ command: String) -> String {
    guard FileManager.default.fileExists(atPath: claudeHooksScript), let binary = Bundle.main.executablePath else { return "missing" }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    task.arguments = ["-I", claudeHooksScript, command, binary]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = out
    do { try task.run() } catch { return "python3 not available" }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    task.waitUntilExit()
    log("claude hooks \(command): \(text)")
    return text
}
