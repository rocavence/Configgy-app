import Foundation

/// What Configgy remembers between launches (status.json): the last result of
/// each target, which snapshot Zen is on, and which backups were already
/// checked for secrets.
struct StatusFile: Codable, Sendable {
    struct Result: Codable, Equatable, Sendable {
        var date: Date
        var ok: Bool
        var message: String?
    }

    var results: [String: Result] = [:]
    /// The Zen snapshot the profile matches, so a newer one from another Mac can be offered.
    var zenCurrent: String?
    /// A newer Zen snapshot the user chose not to restore.
    var zenDismissed: String?
    /// Snapshot names already checked for secrets and found clean.
    var scanned: [String] = []

    static func path(_ home: String) -> String { home + "/Library/Application Support/Configgy/status.json" }

    static func load(_ home: String) -> StatusFile {
        guard let data = FileManager.default.contents(atPath: path(home)) else { return StatusFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(StatusFile.self, from: data)) ?? StatusFile()
    }

    func save(_ home: String) {
        try? FileManager.default.createDirectory(atPath: (Self.path(home) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: URL(fileURLWithPath: Self.path(home)), options: .atomic) }
    }

    /// Loads, changes and saves in one go.
    static func update(_ home: String, _ change: (inout StatusFile) -> Void) {
        var file = load(home)
        change(&file)
        file.save(home)
    }
}
