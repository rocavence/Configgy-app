import Foundation

/// What a restore will write: each file from the unpacked snapshot to its place
/// on this Mac. Paths that fall outside the target, or are secrets, are listed
/// in `rejected` and never written.
struct RestorePlan: Sendable {
    struct Write: Sendable, Hashable {
        let source: String
        let destination: String
    }

    var writes: [Write] = []
    var rejected: [String] = []
}

/// What a restore would change, by comparing each planned write with what's there.
struct ChangeSet: Sendable, Equatable {
    var modified: [String] = []
    var added: [String] = []
    var rejected: [String] = []

    var isEmpty: Bool { modified.isEmpty && added.isEmpty }
    var count: Int { modified.count + added.count }
}

/// A thing Configgy backs up: Zen, Claude Code, or a set of files and folders.
/// Backup, restore, retention and safety are shared (`BackupService`); a target
/// only says what to copy and where it goes back.
protocol BackupTarget: Sendable {
    /// "zen", "claude", or "t:<id>"; also names the status entry.
    var key: String { get }
    var name: String { get }
    var bundleID: String? { get }
    var store: SnapshotStore { get }
    /// An app that must be closed while backing up or restoring.
    var appToClose: (bundleID: String, name: String)? { get }

    /// Copies what's to be backed up into `snapshot` (the folder that becomes the zip's `snapshot/`).
    func stage(into snapshot: String) throws
    /// Where each file of an unpacked snapshot goes back.
    func restorePlan(from snapshot: String) throws -> RestorePlan
}

extension BackupTarget {
    var appToClose: (bundleID: String, name: String)? { nil }
}

enum FileCopy {
    /// Copies every regular file under `source` into `destination` for which
    /// `include(relativePath)` is true. Symlinks are skipped. Returns the count.
    @discardableResult
    static func tree(_ source: String, to destination: String, include: (String) -> Bool) throws -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            guard include((source as NSString).lastPathComponent) else { return 0 }
            try file(source, to: destination)
            return 1
        }
        var count = 0
        let enumerator = fm.enumerator(at: URL(fileURLWithPath: source), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
            let rel = String(url.path.dropFirst(source.count + 1))
            guard include(rel) else { continue }
            try file(url.path, to: destination + "/" + rel)
            count += 1
        }
        return count
    }

    static func file(_ source: String, to destination: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
        try fm.copyItem(atPath: source, toPath: destination)
    }

    /// Every regular file under `root`, as paths relative to it.
    static func files(under root: String) -> [String] {
        let fm = FileManager.default
        return (fm.enumerator(atPath: root)?.allObjects as? [String] ?? []).filter { rel in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: root + "/" + rel, isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
    }

    static func sameContent(_ a: String, _ b: String) -> Bool {
        let fm = FileManager.default
        let sizeA = (try? fm.attributesOfItem(atPath: a))?[.size] as? Int
        let sizeB = (try? fm.attributesOfItem(atPath: b))?[.size] as? Int
        guard sizeA == sizeB, let dataA = fm.contents(atPath: a), let dataB = fm.contents(atPath: b) else { return false }
        return dataA == dataB
    }
}
