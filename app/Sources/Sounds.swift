// The sounds an agent bubble can play, and which one is chosen for each event.
//
// Three places are offered, in this order: the user's own files (any wav, aiff, mp3, m4a or caf
// dropped into the sounds folder), the chimes bundled with the app (made by scripts/make-sounds.py),
// and the macOS system sounds.
import Cocoa

enum SoundEvent: String {
    case finished = "agentSoundFinished"
    case needsYou = "agentSoundNeedsYou"

    var fallback: String { self == .finished ? "Glass" : "Ping" }
    var chosen: String { UserDefaults.standard.string(forKey: rawValue) ?? fallback }
}

enum AgentSound {
    static let customDir = configDir + "/sounds"
    static var bundledDir: String { (Bundle.main.resourcePath ?? "") + "/Sounds" }
    static let systemDir = "/System/Library/Sounds"
    private static let extensions: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]
    private static var playing: NSSound?   // kept so the sound is not released while it plays

    /// Sound names (file names without extension) in a folder, sorted.
    static func names(in dir: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The groups shown in Settings: own files, bundled, system.
    static var groups: [[String]] { [names(in: customDir), names(in: bundledDir), names(in: systemDir)] }

    private static func path(for name: String) -> String? {
        for dir in [customDir, bundledDir, systemDir] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            where (file as NSString).deletingPathExtension == name && extensions.contains((file as NSString).pathExtension.lowercased()) {
                return "\(dir)/\(file)"
            }
        }
        return nil
    }

    static func play(_ name: String) {
        guard let path = path(for: name), let sound = NSSound(contentsOfFile: path, byReference: true) else {
            log("agents: sound not found, using the system beep")
            NSSound.beep()
            return
        }
        playing?.stop()
        playing = sound
        sound.play()
        // Some meme clips run for 15 seconds or more: a notification stops after a few.
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds) {
            if playing === sound { sound.stop(); playing = nil }
        }
    }

    static let maxSeconds: TimeInterval = 5

    static func play(_ event: SoundEvent) { play(event.chosen) }
}
