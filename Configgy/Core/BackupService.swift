import Foundation

/// Backup and restore, the same for every target.
///
/// Backup: stage → skip if unchanged → zip and test locally → move into the
/// cloud folder → prune this machine's old snapshots.
/// Restore: unpack and test → plan (only the target's own paths, never secrets)
/// → save the current state as a "before restore" snapshot and check it → write.
enum BackupService {
    enum BackupOutcome: Equatable, Sendable {
        case created(Snapshot)
        case unchanged
    }

    struct RestoreOutcome: Sendable {
        var written: Int
        var rejected: [String]
        var preRestore: Snapshot?
        var notes: [String] = []
    }

    // MARK: Backup

    static func backup(_ target: BackupTarget, context: Context) throws -> BackupOutcome {
        do {
            _ = try BackupLocation.requireUsable(context.base)
            let outcome = try TempDir.with("backup") { temp -> BackupOutcome in
                let snapshot = temp + "/snapshot"
                try FileManager.default.createDirectory(atPath: snapshot, withIntermediateDirectories: true)
                try target.stage(into: snapshot)
                let (hash, files) = Hashing.directory(snapshot)
                guard files > 0 else { throw ConfiggyError.nothingToBackUp }
                if target.store.newest()?.meta?.hash == hash { return .unchanged }

                let now = Date()
                let meta = SnapshotMeta(host: context.host, ts: SnapshotStore.stamp(now), iso: ISO8601DateFormatter().string(from: now),
                                        hash: hash, files: files, summary: target is ZenTarget ? ZenTarget.summary(of: snapshot) : nil)
                try JSONEncoder().encode(meta).write(to: URL(fileURLWithPath: snapshot + "/meta.json"))
                return .created(try target.store.write(stagedIn: temp, meta: meta))
            }
            switch outcome {
            case .created(let snapshot): Log.write("Backed up \(target.name) → \(snapshot.name) (\(snapshot.meta?.files ?? 0) files)", home: context.home)
            case .unchanged: Log.write("\(target.name) unchanged; no new backup", home: context.home)
            }
            record(target.key, ok: true, message: nil, context: context)
            if case .created(let snapshot) = outcome, target is ZenTarget {
                StatusFile.update(context.home) { $0.zenCurrent = snapshot.name; $0.zenDismissed = nil }
            }
            return outcome
        } catch {
            Log.write("Backup of \(target.name) failed: \(error.localizedDescription)", home: context.home, error: true)
            record(target.key, ok: false, message: error.localizedDescription, context: context)
            throw error
        }
    }

    // MARK: Restore

    /// Unpacks a snapshot into `temp` and returns its `snapshot` folder.
    static func unpack(_ snapshot: Snapshot, into temp: String) throws -> String {
        try SnapshotStore.extract(snapshot, into: temp)
    }

    /// What applying `plan` would change on this Mac.
    static func preview(_ plan: RestorePlan) -> ChangeSet {
        let fm = FileManager.default
        var changes = ChangeSet(rejected: plan.rejected)
        for write in plan.writes {
            if !fm.fileExists(atPath: write.destination) {
                changes.added.append(write.destination)
            } else if !FileCopy.sameContent(write.source, write.destination) {
                changes.modified.append(write.destination)
            }
        }
        return changes
    }

    /// Saves the files `plan` would overwrite as a "before restore" snapshot
    /// (kept locally, 5 per target), tests it, then writes. Nothing is written
    /// unless that copy succeeded.
    static func apply(_ plan: RestorePlan, target: BackupTarget, label: String, context: Context) throws -> RestoreOutcome {
        do {
            let pre = try savePreRestore(plan, target: target, context: context)
            for write in plan.writes { try FileCopy.file(write.source, to: write.destination) }
            Log.write("Restored \(target.name) from \(label): \(plan.writes.count) files written, \(plan.rejected.count) skipped"
                      + (pre.map { ", previous state saved as \($0.name)" } ?? ""), home: context.home)
            record(target.key, ok: true, message: nil, context: context)
            return RestoreOutcome(written: plan.writes.count, rejected: plan.rejected, preRestore: pre)
        } catch {
            Log.write("Restore of \(target.name) failed: \(error.localizedDescription)", home: context.home, error: true)
            record(target.key, ok: false, message: error.localizedDescription, context: context)
            throw error
        }
    }

    static func preRestoreStore(for target: BackupTarget, context: Context) -> SnapshotStore {
        let safeKey = target.key.replacingOccurrences(of: ":", with: "-")
        return SnapshotStore(directory: context.supportDir + "/before-restore/" + safeKey, prefix: "before-\(safeKey)-", host: context.host, keep: 5)
    }

    private static func savePreRestore(_ plan: RestorePlan, target: BackupTarget, context: Context) throws -> Snapshot? {
        let existing = plan.writes.map(\.destination).filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        return try TempDir.with("before") { temp in
            let snapshot = temp + "/snapshot"
            for path in existing {
                let rel = path.hasPrefix(context.home + "/") ? "home/" + path.dropFirst(context.home.count + 1) : "abs" + path
                try FileCopy.file(path, to: snapshot + "/files/" + rel)
            }
            let (hash, files) = Hashing.directory(snapshot)
            let now = Date()
            let meta = SnapshotMeta(host: context.host, ts: SnapshotStore.stamp(now), iso: ISO8601DateFormatter().string(from: now), hash: hash, files: files)
            return try preRestoreStore(for: target, context: context).write(stagedIn: temp, meta: meta)
        }
    }

    static func record(_ key: String, ok: Bool, message: String?, context: Context) {
        StatusFile.update(context.home) { $0.results[key] = .init(date: Date(), ok: ok, message: message) }
    }

    // MARK: Secrets already in the cloud

    struct Finding: Sendable, Identifiable, Hashable {
        let snapshot: Snapshot
        let targetName: String
        let paths: [String]

        var id: String { snapshot.path }
    }

    /// Checks snapshots not checked before for files the secret filter now
    /// blocks. Clean ones are remembered so each zip is only read once.
    static func scanForSecrets(_ targets: [BackupTarget], context: Context) -> [Finding] {
        var scanned = Set(StatusFile.load(context.home).scanned)
        var findings: [Finding] = []
        for target in targets {
            for snapshot in target.store.list() where !scanned.contains(snapshot.name) {
                guard let entries = try? SnapshotStore.contents(of: snapshot.path) else { continue }
                let bad = entries.filter { entry in
                    let rel = entry.split(separator: "/").dropFirst().joined(separator: "/")   // drop "snapshot/"
                    return !entry.hasSuffix("/") && Sensitive.isSensitive(rel)
                }
                if bad.isEmpty { scanned.insert(snapshot.name) } else { findings.append(Finding(snapshot: snapshot, targetName: target.name, paths: bad)) }
            }
        }
        StatusFile.update(context.home) { $0.scanned = Array(scanned).sorted() }
        return findings
    }

    /// Rewrites a snapshot without its secret files: unpack, remove, re-zip,
    /// test, then replace the original.
    static func repack(_ finding: Finding, context: Context) throws {
        let fm = FileManager.default
        try TempDir.with("repack") { temp in
            let local = temp + "/original.zip"
            try fm.copyItem(atPath: finding.snapshot.path, toPath: local)
            try Shell.run("/usr/bin/unzip", ["-qo", local, "-d", temp + "/unpacked"])
            for entry in finding.paths { try? fm.removeItem(atPath: temp + "/unpacked/" + entry) }
            let clean = temp + "/clean.zip"
            try Shell.run("/usr/bin/zip", ["-rqy", clean, "snapshot"], cwd: temp + "/unpacked")
            try Shell.run("/usr/bin/unzip", ["-tq", clean])
            let partial = finding.snapshot.path + ".partial"
            try? fm.removeItem(atPath: partial)
            try fm.copyItem(atPath: clean, toPath: partial)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: finding.snapshot.path), withItemAt: URL(fileURLWithPath: partial))
        }
        StatusFile.update(context.home) { $0.scanned.append(finding.snapshot.name) }
        Log.write("Removed \(finding.paths.count) secret files from \(finding.snapshot.name)", home: context.home)
    }

    static func deleteSnapshot(_ finding: Finding, context: Context) {
        try? FileManager.default.removeItem(atPath: finding.snapshot.path)
        try? FileManager.default.removeItem(atPath: finding.snapshot.path + ".json")
        Log.write("Deleted \(finding.snapshot.name), which held secret files", home: context.home)
    }
}
