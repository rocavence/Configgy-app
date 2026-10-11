import Foundation

/// The cloud folders Configgy can keep backups in, and whether the chosen one is usable.
enum BackupLocation {
    enum Provider: String, CaseIterable, Sendable {
        case dropbox, icloud, googleDrive, custom

        var title: String {
            switch self {
            case .dropbox: "Dropbox"
            case .icloud: "iCloud Drive"
            case .googleDrive: "Google Drive"
            case .custom: String(localized: "Other Folder")
            }
        }
    }

    enum Status: Equatable, Sendable {
        case ok
        /// No folder chosen, and no Dropbox to fall back on.
        case notChosen
        /// Chosen, but the folder (or the cloud folder it lives in) is gone.
        case missing(String)
        /// There, but Configgy can't write to it: usually Full Disk Access.
        case notWritable(String)
    }

    /// The Configgy folder inside each provider's local sync folder, if that provider is set up here.
    static func detect(_ provider: Provider, home: String) -> String? {
        let fm = FileManager.default
        switch provider {
        case .dropbox:
            for root in [home + "/Dropbox", home + "/Library/CloudStorage/Dropbox"] where fm.fileExists(atPath: root) {
                return root + "/Apps/Configgy"
            }
            return nil
        case .icloud:
            let root = home + "/Library/Mobile Documents/com~apple~CloudDocs"
            return fm.fileExists(atPath: root) ? root + "/Configgy" : nil
        case .googleDrive:
            let storage = home + "/Library/CloudStorage"
            guard let drive = (try? fm.contentsOfDirectory(atPath: storage))?.first(where: { $0.hasPrefix("GoogleDrive-") }) else { return nil }
            let myDrive = storage + "/" + drive + "/My Drive"
            return (fm.fileExists(atPath: myDrive) ? myDrive : storage + "/" + drive) + "/Configgy"
        case .custom:
            return nil
        }
    }

    /// The folder in use: the one chosen in Settings, else Dropbox's if Dropbox is set up.
    static func resolve(home: String) -> String? {
        if let chosen = ConfiggySettings.load(home).backupBase, !chosen.isEmpty { return chosen }
        return detect(.dropbox, home: home)
    }

    static func provider(of base: String, home: String) -> Provider {
        Provider.allCases.first { $0 != .custom && detect($0, home: home) == base } ?? .custom
    }

    /// Checks the folder without creating anything outside it: its parent (the
    /// cloud folder) must exist, and a probe file must be writable.
    static func status(_ base: String?) -> Status {
        guard let base else { return .notChosen }
        let fm = FileManager.default
        let parent = (base as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: parent) else { return .missing(base) }
        try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        let probe = base + "/.configgy-probe"
        guard (try? Data("ok".utf8).write(to: URL(fileURLWithPath: probe))) != nil else { return .notWritable(base) }
        try? fm.removeItem(atPath: probe)
        return .ok
    }

    /// The location error to throw before a backup, if any.
    static func requireUsable(_ base: String?) throws -> String {
        switch status(base) {
        case .ok: return base!
        case .notChosen: throw ConfiggyError.noLocation
        case .missing(let path), .notWritable(let path): throw ConfiggyError.locationUnavailable(path)
        }
    }
}
