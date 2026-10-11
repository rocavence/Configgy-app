import Foundation

/// Persisted settings, ~/Library/Application Support/Configgy/settings.json.
/// Unknown or missing keys fall back to defaults, so files from older versions load.
struct ConfiggySettings: Codable, Equatable, Sendable {
    /// The "Configgy" folder inside the chosen cloud folder; nil means detect Dropbox.
    var backupBase: String?
    /// Zen is opt-in: added from the suggestions, or found in the backup folder.
    var zenEnabled = false
    /// Back Zen up automatically each time it quits.
    var zenAutoBackup = true
    /// Snapshots kept per target, counted per machine.
    var keep = 10
    /// Patterns never copied from custom folders (on top of the built-in secret filter).
    var folderExcludes = Sensitive.defaultFolderExcludes
    /// The first-run guide has been completed.
    var onboarded = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backupBase = try c.decodeIfPresent(String.self, forKey: .backupBase)
        zenEnabled = try c.decodeIfPresent(Bool.self, forKey: .zenEnabled) ?? false
        zenAutoBackup = try c.decodeIfPresent(Bool.self, forKey: .zenAutoBackup) ?? true
        keep = max(1, try c.decodeIfPresent(Int.self, forKey: .keep) ?? 10)
        folderExcludes = try c.decodeIfPresent([String].self, forKey: .folderExcludes) ?? Sensitive.defaultFolderExcludes
        // Someone who set Configgy up before the guide existed has nothing to be guided through.
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? (backupBase != nil || zenEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case backupBase, zenEnabled, zenAutoBackup, keep, folderExcludes, onboarded
    }

    static func path(_ home: String) -> String { home + "/Library/Application Support/Configgy/settings.json" }

    static func load(_ home: String) -> ConfiggySettings {
        guard let data = FileManager.default.contents(atPath: path(home)),
              let settings = try? JSONDecoder().decode(ConfiggySettings.self, from: data) else { return ConfiggySettings() }
        return settings
    }

    func save(_ home: String) {
        let file = Self.path(home)
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: URL(fileURLWithPath: file), options: .atomic) }
    }
}
