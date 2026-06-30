import Foundation

// Persisted app settings (~/Library/Application Support/Configgy/settings.json).
struct ConfiggySettings: Codable {
    var backupBase: String? = nil   // full path to the "Configgy" backup folder; nil → auto-detect
    var language: String? = nil     // "zh" | "en" | nil (follow system)
}

// Detect the local sync folder of each cloud provider; returns the Configgy
// base path inside it, or nil if that provider isn't set up on this Mac.
enum BackupLoc {
    static func dropbox(_ home: String) -> String? {
        for b in [home + "/Dropbox", home + "/Library/CloudStorage/Dropbox"] {
            if FileManager.default.fileExists(atPath: b) { return b + "/Apps/Configgy" }
        }
        return nil
    }
    static func icloud(_ home: String) -> String? {
        let p = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        return FileManager.default.fileExists(atPath: p) ? p + "/Configgy" : nil
    }
    static func gdrive(_ home: String) -> String? {
        let cs = home + "/Library/CloudStorage"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: cs),
              let g = items.first(where: { $0.hasPrefix("GoogleDrive-") }) else { return nil }
        let root = cs + "/" + g
        let myDrive = root + "/My Drive"
        return (FileManager.default.fileExists(atPath: myDrive) ? myDrive : root) + "/Configgy"
    }
}

enum Settings {
    static func path(_ home: String) -> String { home + "/Library/Application Support/Configgy/settings.json" }
    static func load(_ home: String) -> ConfiggySettings {
        guard let d = FileManager.default.contents(atPath: path(home)),
              let s = try? JSONDecoder().decode(ConfiggySettings.self, from: d) else { return ConfiggySettings() }
        return s
    }
    static func save(_ s: ConfiggySettings, home: String) {
        let dir = (path(home) as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: URL(fileURLWithPath: path(home))) }
    }
}
