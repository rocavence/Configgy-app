import CryptoKit
import Foundation

/// What a snapshot holds, written into it (snapshot/meta.json) and next to it as
/// a small sidecar (`<name>.json`) so the list never has to open the zip, which
/// would make Dropbox download "online-only" files.
struct SnapshotMeta: Codable, Hashable, Sendable {
    var host: String
    var ts: String
    var iso: String
    var hash: String
    var files: Int
    var summary: ZenSummary?
}

struct ZenSummary: Codable, Hashable, Sendable {
    var workspaces: [String]
    var tabs: Int
    var pinned: Int
    var essentials: Int
}

struct Snapshot: Hashable, Sendable, Identifiable {
    let name: String
    let path: String
    let host: String
    let date: Date?
    let meta: SnapshotMeta?

    var id: String { name }
}

/// One folder of versioned zips for one target: naming, listing, writing (with
/// verification), retention, and extraction.
struct SnapshotStore: Sendable {
    let directory: String
    /// The name prefix new snapshots get, e.g. "configgy-zen-".
    let prefix: String
    /// Older prefixes still listed and restorable (e.g. "zennly-").
    var legacyPrefixes: [String] = []
    let host: String
    var keep = 10

    static let stampFormat = "yyyyMMdd-HHmmss"

    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = stampFormat
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    static func date(fromStamp stamp: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = stampFormat
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: stamp)
    }

    /// Splits `<prefix><host>-<yyyyMMdd-HHmmss>.zip` into host and date.
    func parse(_ name: String) -> (host: String, date: Date?)? {
        guard name.hasSuffix(".zip"), let p = ([prefix] + legacyPrefixes).first(where: { name.hasPrefix($0) }) else { return nil }
        let body = String(name.dropFirst(p.count).dropLast(4))
        guard body.count > 16 else { return nil }
        let stamp = String(body.suffix(15))
        let host = String(body.dropLast(16))
        return (host, Self.date(fromStamp: stamp))
    }

    /// Oldest first, ordered by time (not by name, so hosts interleave correctly).
    func list() -> [Snapshot] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { name -> Snapshot? in
            guard let parsed = parse(name) else { return nil }
            let path = directory + "/" + name
            let meta = fm.contents(atPath: path + ".json").flatMap { try? JSONDecoder().decode(SnapshotMeta.self, from: $0) }
            return Snapshot(name: name, path: path, host: parsed.host, date: parsed.date, meta: meta)
        }
        .sorted { ($0.date ?? .distantPast, $0.name) < ($1.date ?? .distantPast, $1.name) }
    }

    func newest() -> Snapshot? { list().last }

    /// Zips `root/snapshot` into the store. The zip is written and tested
    /// locally first, then copied in under a temporary name and renamed, so the
    /// cloud folder never holds a half-written backup. Then prunes this machine's
    /// old snapshots beyond `keep`.
    func write(stagedIn root: String, meta: SnapshotMeta) throws -> Snapshot {
        let fm = FileManager.default
        let name = "\(prefix)\(host)-\(meta.ts).zip"
        let localZip = root + "/" + name
        try Shell.run("/usr/bin/zip", ["-rqy", localZip, "snapshot"], cwd: root)
        try Shell.run("/usr/bin/unzip", ["-tq", localZip])

        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let final = directory + "/" + name, partial = final + ".partial"
        try? fm.removeItem(atPath: partial)
        do {
            try fm.copyItem(atPath: localZip, toPath: partial)
            try fm.moveItem(atPath: partial, toPath: final)
        } catch {
            try? fm.removeItem(atPath: partial)
            throw error
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta).write(to: URL(fileURLWithPath: final + ".json"))
        prune()
        return Snapshot(name: name, path: final, host: host, date: Self.date(fromStamp: meta.ts), meta: meta)
    }

    /// Keeps the newest `keep` snapshots made on this machine; other machines' are left alone.
    func prune() {
        let mine = list().filter { $0.host == host }
        guard mine.count > keep else { return }
        for old in mine.prefix(mine.count - keep) { delete(old) }
    }

    func delete(_ snapshot: Snapshot) {
        try? FileManager.default.removeItem(atPath: snapshot.path)
        try? FileManager.default.removeItem(atPath: snapshot.path + ".json")
    }

    /// Copies the zip to a local temp folder (so a cloud placeholder downloads in
    /// full), tests it, and unpacks it. Returns the unpacked `snapshot` folder.
    static func extract(_ snapshot: Snapshot, into temp: String) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshot.path) else { throw ConfiggyError.notFound(snapshot.name) }
        let local = temp + "/archive.zip"
        try fm.copyItem(atPath: snapshot.path, toPath: local)
        do { try Shell.run("/usr/bin/unzip", ["-tq", local]) } catch {
            throw ConfiggyError.badSnapshot(String(localized: "the zip is damaged"))
        }
        try Shell.run("/usr/bin/unzip", ["-qo", local, "-d", temp + "/unpacked"])
        let root = temp + "/unpacked/snapshot"
        guard fm.fileExists(atPath: root) else { throw ConfiggyError.badSnapshot(String(localized: "it has no snapshot folder")) }
        return root
    }

    /// The paths inside a zip, without unpacking it.
    static func contents(of path: String) throws -> [String] {
        let out = try Shell.run("/usr/bin/zipinfo", ["-1", path])
        return String(decoding: out, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// A scratch folder that's removed when done.
enum TempDir {
    static func with<T>(_ label: String, _ body: (String) throws -> T) throws -> T {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("configgy-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        return try body(dir)
    }
}

enum Hashing {
    /// A digest of every file's relative path and contents under `root`, and how many files there are.
    static func directory(_ root: String) -> (hash: String, files: Int) {
        let fm = FileManager.default
        var sha = Insecure.SHA1()
        var count = 0
        let paths = (fm.enumerator(atPath: root)?.allObjects as? [String] ?? []).sorted()
        for rel in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root + "/" + rel, isDirectory: &isDir), !isDir.boolValue else { continue }
            count += 1
            sha.update(data: Data(rel.utf8))
            if let data = fm.contents(atPath: root + "/" + rel) { sha.update(data: data) }
        }
        return (sha.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}
