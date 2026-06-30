import Foundation

// Persisted app settings (~/Library/Application Support/Configgy/settings.json).
struct ConfiggySettings: Codable {
    var backupBase: String? = nil   // full path to the "Configgy" backup folder; nil → auto-detect
    var language: String? = nil     // "zh" | "en" | nil (follow system)
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
