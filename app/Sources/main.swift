// Profile Bubbles: a column of always-on-top bubbles on the left edge of the screen,
// one per Chrome profile. Click a bubble to open a Chrome window in that profile.
import Cocoa
import Carbon.HIToolbox
import ServiceManagement

/// UI text: Vietnamese when that is the user's first language, English otherwise.
func tr(_ en: String, _ vi: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("vi") ? vi : en
}

// MARK: - Profiles

struct Profile {
    let dir: String        // "Default", "Profile 1", ...
    let name: String
    let email: String
    var gaiaName = ""      // Google account name; Chrome may show it in its Profiles menu
    let picture: String?   // path to the Google account picture, if Chrome saved one
    let color: NSColor
    var signature: String { "\(dir)|\(name)|\(email)|\(picture ?? "")" }
}

let chromeDir = NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
let localStatePath = chromeDir + "/Local State"
let configDir = NSHomeDirectory() + "/Library/Application Support/ProfileBubbles"
let configPath = configDir + "/profiles.json"
let logPath = NSHomeDirectory() + "/Library/Logs/ProfileBubbles.log"

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink,
                          .systemPurple, .systemTeal, .systemRed, .systemIndigo]

func fallbackColor(_ key: String) -> NSColor {
    palette[key.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
}

func color(hex: String) -> NSColor? {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

/// Optional hand-written list: [{"dir": "Default", "name": "Personal", "color": "#1a73e8", "image": "/path.png"}].
/// When it exists it wins over Chrome's own list, so it also works without access to Chrome's data.
func loadConfiguredProfiles() -> [Profile]? {
    guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
    guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        log("profiles.json is not a JSON list of objects")
        return nil
    }
    let profiles: [Profile] = items.compactMap { item in
        guard let dir = item["dir"] as? String, !dir.isEmpty else { return nil }
        let image = (item["image"] as? String).map { NSString(string: $0).expandingTildeInPath }
        return Profile(dir: dir, name: item["name"] as? String ?? dir, email: "",
                       picture: image.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil },
                       color: (item["color"] as? String).flatMap(color(hex:)) ?? fallbackColor(dir))
    }
    return profiles.isEmpty ? nil : profiles
}

func loadProfiles() -> [Profile] {
    if let configured = loadConfiguredProfiles() { return configured }
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: localStatePath))
    } catch {
        log("cannot read Local State: \(error.localizedDescription) [\((error as NSError).domain) \((error as NSError).code)]")
        return []
    }
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let section = root["profile"] as? [String: Any],
          let cache = section["info_cache"] as? [String: Any] else {
        log("Local State has no profile.info_cache")
        return []
    }
    let order = section["profiles_order"] as? [String] ?? []
    var result: [Profile] = []
    for (dir, value) in cache {
        guard let info = value as? [String: Any] else { continue }
        let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dir
        let email = info["user_name"] as? String ?? ""
        var picture: String?
        if let file = info["gaia_picture_file_name"] as? String, !file.isEmpty {
            let path = "\(chromeDir)/\(dir)/\(file)"
            if FileManager.default.fileExists(atPath: path) { picture = path }
        }
        var color = fallbackColor(dir)
        if let argb = info["default_avatar_fill_color"] as? Int {
            let v = UInt32(truncatingIfNeeded: argb)
            color = NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        result.append(Profile(dir: dir, name: name, email: email, gaiaName: info["gaia_name"] as? String ?? "",
                              picture: picture, color: color))
    }
    func rank(_ p: Profile) -> Int { order.firstIndex(of: p.dir) ?? (p.dir == "Default" ? -1 : Int.max) }
    result.sort {
        let (a, b) = (rank($0), rank($1))
        return a != b ? a < b : $0.dir.compare($1.dir, options: .numeric) == .orderedAscending
    }
    return result
}

func openChrome(profileDir: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", "-a", "Google Chrome", "--args", "--profile-directory=\(profileDir)"]
    do { try task.run() } catch { log("open failed: \(error)") }
}

// MARK: - Focus an existing Chrome window (Accessibility)

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
}

func axTitle(_ element: AXUIElement) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return "" }
    return value as? String ?? ""
}

func menuTitle(_ title: String, matches p: Profile) -> Bool {
    if title.isEmpty { return false }
    // Chrome shows "<given name> (<profile name>)" when the two differ, else the profile name alone.
    if title == p.name || title.hasSuffix(" (\(p.name))") { return true }
    if p.gaiaName.isEmpty { return false }
    return title == p.gaiaName || title == "\(p.gaiaName) (\(p.name))" || title == "\(p.name) (\(p.gaiaName))"
}

func chromeElement() -> (NSRunningApplication, AXUIElement)? {
    guard AXIsProcessTrusted(),
          let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first
    else { return nil }
    let app = AXUIElementCreateApplication(chrome.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1.5)
    return (chrome, app)
}

func chromeWindows(_ app: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
}

/// Chrome's Profiles menu item for a profile, found by content so Chrome's language does not matter.
func profileMenuItem(_ app: AXUIElement, for profile: Profile, among all: [Profile]) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
          let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
    var best: [AXUIElement] = []
    var bestScore = 0
    for top in axChildren(bar as! AXUIElement).dropFirst() {   // skip the Apple menu
        let items = axChildren(top).flatMap(axChildren)
        let titles = items.map(axTitle)
        let score = all.filter { p in titles.contains { menuTitle($0, matches: p) } }.count
        if score > bestScore { bestScore = score; best = items }
    }
    return best.first { menuTitle(axTitle($0), matches: profile) }
}

/// The Window menu (second to last in the menu bar) lists windows on every Space, including
/// full-screen ones, which the window list above cannot see. Pressing an item switches to it.
func windowMenuItem(_ app: AXUIElement, label: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
          let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
    let tops = axChildren(bar as! AXUIElement)
    guard tops.count >= 3 else { return nil }
    let items = axChildren(tops[tops.count - 2]).flatMap(axChildren)
    let shape = items.map { item -> String in
        let t = axTitle(item)
        return t.isEmpty ? "-" : (t.contains("Google Chrome") ? "GC:" + profileSuffix(t) : "plain")
    }
    log("focus: window menu items=[\(shape.joined(separator: " | "))]")
    return items.first { item in
        let t = axTitle(item)
        return [" – ", " - ", " — "].contains { t.hasSuffix($0 + label) }
    }
}

/// Chrome window titles end with "… - Google Chrome – <profile label>" when several profiles exist.
func windowTitle(_ title: String, belongsTo label: String) -> Bool {
    guard !label.isEmpty, title.hasSuffix(label) else { return false }
    let rest = String(title.dropLast(label.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -–—"))
    return rest.hasSuffix("Google Chrome")
}

/// Only the part after "Google Chrome", so page titles never reach the log.
func profileSuffix(_ title: String) -> String {
    guard let range = title.range(of: "Google Chrome", options: .backwards) else { return "?" }
    return String(title[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " -–—"))
}

/// Bring the profile's existing Chrome window to the front, keeping its tabs.
/// Returns how it did it, or nil when the caller should open a new window instead.
func focusChromeWindow(of profile: Profile, among all: [Profile]) -> String? {
    guard let (chrome, app) = chromeElement() else { return nil }
    let item = profileMenuItem(app, for: profile, among: all)
    let label = item.map(axTitle) ?? profile.name
    let windows = chromeWindows(app)
    log("focus: label=[\(label)] windows here=[\(windows.map { profileSuffix(axTitle($0)) }.joined(separator: " | "))]")

    if let window = windows.first(where: { windowTitle(axTitle($0), belongsTo: label) }) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        chrome.activate()
        return "raised window"
    }
    if let entry = windowMenuItem(app, label: label),
       AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success {
        chrome.activate()
        return "window menu"
    }
    // No window found anywhere: Chrome's own Profiles menu opens one for this profile.
    if let item = item, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
        chrome.activate()
        return "profiles menu"
    }
    return nil
}

/// Debug aid: write Chrome's menu bar layout and the names we try to match to the log.
func logChromeMenus(profiles: [Profile]) {
    guard AXIsProcessTrusted(),
          let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first
    else { return }
    let app = AXUIElementCreateApplication(chrome.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 1.5)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
          let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return }
    for p in profiles { log("debug profile \(p.dir): name=[\(p.name)] gaia=[\(p.gaiaName)]") }
    let tops = Array(axChildren(bar as! AXUIElement).dropFirst())
    log("debug menus: \(tops.map(axTitle).joined(separator: " | "))")
    for top in tops.suffix(4).dropLast(2) {
        let titles = axChildren(top).flatMap(axChildren).map(axTitle).filter { !$0.isEmpty }
        log("debug menu [\(axTitle(top))]: \(titles.joined(separator: " | "))")
    }
}

// MARK: - Hotkeys (Control+Option+1…9, Carbon: needs no permission)

let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // keys 1…9

func installHotKeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        let index = Int(id.id)
        DispatchQueue.main.async { AppDelegate.shared?.activate(index: index) }
        return noErr
    }, 1, &spec, nil, nil)
    var failed: [Int] = []
    for (index, code) in digitKeyCodes.enumerated() {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5042_4C42, id: UInt32(index))
        if RegisterEventHotKey(code, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref) != noErr {
            failed.append(index + 1)
        }
    }
    log(failed.isEmpty ? "hotkeys: Control+Option+1…9 registered"
                       : "hotkeys: could not register \(failed) (taken by another app?)")
}

// MARK: - Bubble

enum Position: String, CaseIterable {
    case left, right, notch, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .left: return tr("Left edge", "Mép trái")
        case .right: return tr("Right edge", "Mép phải")
        case .notch: return tr("Around the notch", "Quanh tai thỏ")
        case .bottomLeft: return tr("Bottom left", "Góc dưới trái")
        case .bottomRight: return tr("Bottom right", "Góc dưới phải")
        }
    }
    var isSideColumn: Bool { self == .left || self == .right }

    static var current: Position {
        Position(rawValue: UserDefaults.standard.string(forKey: "position") ?? "") ?? .left
    }
}

let sizeChoices: [(title: String, points: CGFloat)] = [
    (tr("Small", "Nhỏ"), 40), (tr("Medium", "Vừa"), 52), (tr("Large", "Lớn"), 64)]

var preferredBubbleSize: CGFloat {
    let stored = UserDefaults.standard.double(forKey: "bubbleSize")
    return stored >= 24 ? CGFloat(stored) : 52
}

final class BubbleView: NSView {
    let profile: Profile
    private let image: NSImage?
    weak var controller: AppDelegate?
    var index = 0
    private var hovering = false { didSet { needsDisplay = true } }
    private var downAt = NSPoint.zero
    private var originAtDown = NSPoint.zero
    private var dragged = false

    init(profile: Profile, size: CGFloat) {
        self.profile = profile
        self.image = profile.picture.flatMap { NSImage(contentsOfFile: $0) }
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.width * (hovering ? 0.06 : 0.115)
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let circle = NSBezierPath(ovalIn: rect)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        profile.color.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        if let image = image, image.size.width > 0, image.size.height > 0 {
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height))
        } else {
            let letter = String(profile.name.prefix(1)).uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: rect.height * 0.45, weight: .semibold),
                .foregroundColor: NSColor.white]
            let size = letter.size(withAttributes: attrs)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                        withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(hovering ? 1 : 0.8).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        controller?.showLabel(for: self)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        controller?.hideLabel()
    }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        originAtDown = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard Position.current.isSideColumn else { return }   // only the side columns can be dragged
        let dy = NSEvent.mouseLocation.y - downAt.y
        if !dragged && abs(dy) < 4 { return }
        dragged = true
        controller?.hideLabel()
        controller?.movePanel(toY: originAtDown.y + dy)
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            controller?.savePosition()
        } else if !profile.dir.isEmpty {
            controller?.activate(profile)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.contextMenu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private let loginItem = NSMenuItem(title: tr("Open at Login", "Mở khi đăng nhập"), action: #selector(toggleLoginItem), keyEquivalent: "")
    private var panel: NSPanel!
    private var labelPanel: NSPanel!
    private var labelField: NSTextField!
    private var signature = ""
    private var lastModified = Date.distantPast
    private var count = 0
    private var profiles: [Profile] = []
    private var askedForAccessibility = false
    let contextMenu = NSMenu()

    private let padding: CGFloat = 4
    private let edgeGap: CGFloat = 4
    private let positionKey = "centerYFraction"

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = makePanel()
        makeLabel()

        let settings = NSMenuItem(title: tr("Settings…", "Cài đặt…"), action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        contextMenu.addItem(settings)
        contextMenu.addItem(.separator())
        let reload = NSMenuItem(title: tr("Reload Profiles", "Tải lại danh sách profile"), action: #selector(reloadNow), keyEquivalent: "")
        reload.target = self
        contextMenu.addItem(reload)
        let edit = NSMenuItem(title: tr("Edit List (profiles.json)", "Sửa danh sách (profiles.json)"), action: #selector(editConfig), keyEquivalent: "")
        edit.target = self
        contextMenu.addItem(edit)
        loginItem.target = self
        contextMenu.addItem(loginItem)
        AppDelegate.shared = self
        installHotKeys()
        setUpLoginItem()
        contextMenu.addItem(.separator())
        contextMenu.addItem(NSMenuItem(title: tr("Quit Profile Bubbles", "Thoát Profile Bubbles"),
                                       action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))

        rebuild(force: true)
        panel.orderFrontRegardless()

        if CommandLine.arguments.contains("--settings") { showSettings() }
        // Test hook: `--activate "<profile dir>"` acts as a click on that bubble right after launch.
        if let i = CommandLine.arguments.firstIndex(of: "--activate"), i + 1 < CommandLine.arguments.count,
           let target = profiles.first(where: { $0.dir == CommandLine.arguments[i + 1] }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.activate(target) }
        }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.rebuild(force: false) }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        return p
    }

    private func makeLabel() {
        labelPanel = makePanel()
        labelPanel.ignoresMouseEvents = true
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        box.layer?.cornerRadius = 6
        labelField = NSTextField(labelWithString: "")
        labelField.textColor = .white
        labelField.font = .systemFont(ofSize: 12, weight: .medium)
        box.addSubview(labelField)
        labelPanel.contentView = box
    }

    private var screenFrame: NSRect { (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero }

    @objc private func reloadNow() { rebuild(force: true) }

    @objc private func editConfig() {
        if !FileManager.default.fileExists(atPath: configPath) {
            try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            let template = "[\n  {\"dir\": \"Default\", \"name\": \"Display name\", \"color\": \"#1a73e8\"}\n]\n"
            FileManager.default.createFile(atPath: configPath, contents: template.data(using: .utf8))
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-t", configPath]
        try? task.run()
    }
    @objc private func screenChanged() { layout() }

    private func rebuild(force: Bool) {
        func mtime(_ path: String) -> Date {
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
        }
        let modified = max(mtime(localStatePath), mtime(configPath))
        if !force && modified == lastModified { return }
        lastModified = modified

        var profiles = loadProfiles()
        if profiles.isEmpty {
            profiles = [Profile(dir: "", name: tr("Cannot read Chrome profiles (right-click for options)", "Không đọc được Chrome profile (chuột phải để xem lựa chọn)"), email: "",
                                picture: nil, color: .systemGray)]
        }
        let newSignature = profiles.map(\.signature).joined(separator: "\n")
        if !force && newSignature == signature { return }
        signature = newSignature
        count = profiles.count
        self.profiles = profiles
        if CommandLine.arguments.contains("--debug-menus") { logChromeMenus(profiles: profiles) }
        log("showing \(count) bubble(s): \(profiles.map(\.dir).joined(separator: ", "))")

        layout()
    }

    private func targetScreen(for position: Position) -> NSScreen? {
        if position == .notch, let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// Builds the bubbles for the chosen position and size, and puts the panel in place.
    func layout() {
        let position = Position.current
        guard let screen = targetScreen(for: position), count > 0 else { return }
        let visible = screen.visibleFrame
        var size = preferredBubbleSize
        let n = CGFloat(count)
        var frame = NSRect.zero
        var origins: [NSPoint] = []

        switch position {
        case .left, .right:
            let height = n * size + padding * 2
            let stored = UserDefaults.standard.object(forKey: positionKey) as? Double
            let centerY = visible.minY + visible.height * CGFloat(stored ?? 0.5)
            let x = position == .left ? visible.minX + edgeGap : visible.maxX - edgeGap - size
            frame = NSRect(x: x, y: clampY(centerY - height / 2, height: height), width: size, height: height)
            origins = (0..<count).map { NSPoint(x: 0, y: height - padding - CGFloat($0 + 1) * size) }
        case .bottomLeft, .bottomRight:
            let width = n * size
            let x = position == .bottomLeft ? visible.minX + edgeGap : visible.maxX - edgeGap - width
            // The real bottom of the screen, not the top of the Dock's strip: a centred Dock leaves
            // the corners free, and the panel floats above the Dock if they ever overlap.
            frame = NSRect(x: x, y: screen.frame.minY + edgeGap, width: width, height: size)
            origins = (0..<count).map { NSPoint(x: CGFloat($0) * size, y: 0) }
        case .notch:
            if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
                // Inside the menu bar strip: first half hugs the notch's left side, the rest its right side.
                size = screen.safeAreaInsets.top
                let leftCount = (count + 1) / 2
                let notchWidth = right.minX - left.maxX
                let leftWidth = CGFloat(leftCount) * size
                frame = NSRect(x: left.maxX - leftWidth, y: screen.frame.maxY - size,
                               width: leftWidth + notchWidth + CGFloat(count - leftCount) * size, height: size)
                origins = (0..<count).map { index in
                    index < leftCount ? NSPoint(x: CGFloat(index) * size, y: 0)
                                      : NSPoint(x: leftWidth + notchWidth + CGFloat(index - leftCount) * size, y: 0)
                }
            } else {
                // No notch on this Mac: a centred row just under the menu bar.
                let width = n * size
                frame = NSRect(x: visible.midX - width / 2, y: visible.maxY - size - edgeGap, width: width, height: size)
                origins = (0..<count).map { NSPoint(x: CGFloat($0) * size, y: 0) }
            }
        }

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        for (index, profile) in profiles.enumerated() {
            let bubble = BubbleView(profile: profile, size: size)
            bubble.controller = self
            bubble.index = index
            bubble.setFrameOrigin(origins[index])
            content.addSubview(bubble)
        }
        hideLabel()
        panel.contentView = content
        panel.setFrame(frame, display: true)
        log("layout: \(position.rawValue), bubble \(Int(size)) pt, frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)), screen \(Int(screen.frame.width))x\(Int(screen.frame.height))")
    }

    private func clampY(_ y: CGFloat, height: CGFloat) -> CGFloat {
        let screen = screenFrame
        return min(max(y, screen.minY), max(screen.minY, screen.maxY - height))
    }

    // MARK: Settings window

    private var settingsWindow: NSWindow?
    private var loginCheckbox: NSButton?

    @objc func showSettings() {
        if settingsWindow == nil {
            let positionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            positionPopup.addItems(withTitles: Position.allCases.map(\.title))
            positionPopup.selectItem(at: Position.allCases.firstIndex(of: Position.current) ?? 0)
            positionPopup.target = self
            positionPopup.action = #selector(positionChanged(_:))

            let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            sizePopup.addItems(withTitles: sizeChoices.map(\.title))
            sizePopup.selectItem(at: sizeChoices.firstIndex { $0.points == preferredBubbleSize } ?? 1)
            sizePopup.target = self
            sizePopup.action = #selector(sizeChanged(_:))

            let login = NSButton(checkboxWithTitle: tr("Open at login", "Mở khi đăng nhập"),
                                 target: self, action: #selector(toggleLoginItem))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            loginCheckbox = login

            let hint = NSTextField(wrappingLabelWithString: tr(
                "Left and right edge: drag a bubble up or down to move the column. Around the notch: bubbles sit in the menu bar and use its height.",
                "Mép trái và mép phải: kéo một bong bóng lên xuống để dời cả cột. Quanh tai thỏ: bong bóng nằm trong thanh menu và cao bằng thanh menu."))
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.preferredMaxLayoutWidth = 230

            let grid = NSGridView(views: [
                [NSTextField(labelWithString: tr("Position:", "Vị trí:")), positionPopup],
                [NSTextField(labelWithString: tr("Bubble size:", "Cỡ bong bóng:")), sizePopup],
                [NSGridCell.emptyContentView, login],
                [NSGridCell.emptyContentView, hint]])
            grid.column(at: 0).xPlacement = .trailing
            grid.rowSpacing = 10
            grid.columnSpacing = 8
            grid.translatesAutoresizingMaskIntoConstraints = false

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = tr("Profile Bubbles Settings", "Cài đặt Profile Bubbles")
            window.isReleasedWhenClosed = false
            let content = NSView()
            content.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
            window.contentView = content
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        log("settings: window shown")
    }

    @objc private func positionChanged(_ sender: NSPopUpButton) {
        let position = Position.allCases[max(0, sender.indexOfSelectedItem)]
        UserDefaults.standard.set(position.rawValue, forKey: "position")
        layout()
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(Double(sizeChoices[max(0, sender.indexOfSelectedItem)].points), forKey: "bubbleSize")
        layout()
    }

    // Launch at login. Turned on once on first run; after that the menu item is the switch.
    private func setUpLoginItem() {
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            do { try SMAppService.mainApp.register() } catch { log("login item: register failed: \(error.localizedDescription)") }
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : .off
        loginCheckbox?.state = loginItem.state
        log("login item: \(status == .enabled ? "enabled" : "not enabled (status \(status.rawValue))")")
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { log("login item: toggle failed: \(error.localizedDescription)") }
        refreshLoginItem()
    }

    func activate(index: Int) {
        guard profiles.indices.contains(index), !profiles[index].dir.isEmpty else { return }
        log("hotkey \(index + 1)")
        activate(profiles[index])
    }

    func activate(_ profile: Profile) {
        if !AXIsProcessTrusted() && !askedForAccessibility {
            askedForAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if let how = focusChromeWindow(of: profile, among: profiles) {
            log("focus \(profile.dir) via \(how)")
            if let (_, app) = chromeElement() {
                let before = chromeWindows(app).count
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    log("focus \(profile.dir): windows on this Space \(before) -> \(chromeWindows(app).count)")
                }
            }
        } else {
            log("open \(profile.dir) (new window)")
            openChrome(profileDir: profile.dir)
        }
    }

    func movePanel(toY y: CGFloat) {
        var frame = panel.frame
        frame.origin.y = clampY(y, height: frame.height)
        panel.setFrameOrigin(frame.origin)
    }

    func savePosition() {
        let screen = screenFrame
        guard screen.height > 0 else { return }
        UserDefaults.standard.set(Double((panel.frame.midY - screen.minY) / screen.height), forKey: positionKey)
    }

    func showLabel(for bubble: BubbleView) {
        let p = bubble.profile
        let title = p.email.isEmpty || p.email == p.name ? p.name : "\(p.name) · \(p.email)"
        labelField.stringValue = bubble.index < digitKeyCodes.count && !p.dir.isEmpty ? "\(title)   ⌃⌥\(bubble.index + 1)" : title
        labelField.sizeToFit()
        let size = NSSize(width: labelField.frame.width + 16, height: labelField.frame.height + 8)
        labelField.setFrameOrigin(NSPoint(x: 8, y: 4))
        let inWindow = bubble.convert(bubble.bounds, to: nil)
        let onScreen = panel.convertToScreen(inWindow)
        var origin: NSPoint
        switch Position.current {
        case .left: origin = NSPoint(x: onScreen.maxX + 4, y: onScreen.midY - size.height / 2)
        case .right: origin = NSPoint(x: onScreen.minX - 4 - size.width, y: onScreen.midY - size.height / 2)
        case .bottomLeft, .bottomRight: origin = NSPoint(x: onScreen.midX - size.width / 2, y: onScreen.maxY + 4)
        case .notch: origin = NSPoint(x: onScreen.midX - size.width / 2, y: onScreen.minY - 4 - size.height)
        }
        if let bounds = panel.screen?.frame ?? NSScreen.screens.first?.frame {
            origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - 4 - size.width)
        }
        labelPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        labelPanel.orderFrontRegardless()
    }

    func hideLabel() { labelPanel.orderOut(nil) }
}

if CommandLine.arguments.contains("--dump") {
    for p in loadProfiles() { print("\(p.dir)\t\(p.name)\t\(p.picture == nil ? "letter" : "photo")") }
    exit(0)
}

let bundleID = Bundle.main.bundleIdentifier ?? ""
if !bundleID.isEmpty,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    exit(0)
}

@_silgen_name("sandbox_check")
func sandbox_check(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32
log("start, sandboxed: \(sandbox_check(getpid(), nil, 0) != 0), accessibility: \(AXIsProcessTrusted())")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
