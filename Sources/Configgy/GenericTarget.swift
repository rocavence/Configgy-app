import Foundation
import CryptoKit

// A user-defined or auto-discovered backup target: an arbitrary set of files/dirs
// snapshotted as versioned, absolute-path-preserving zips — history, diff preview,
// and additive restore, like the Zen/Claude targets but generic.
struct TargetDef: Codable, Equatable {
    var id: String          // slug; used in folder/zip names
    var name: String        // display name
    var paths: [String]     // may contain a leading ~
    var excludes: [String] = []
}
struct TargetMeta: Codable { let host: String; let ts: String; let iso: String; let hash: String; let files: Int }

final class GenericBackup {
    let home: String
    let def: TargetDef
    let dir: String
    let host: String
    let keep = 10
    let isTest = ProcessInfo.processInfo.environment["CONFIGGY_TEST"] != nil
    let fm = FileManager.default

    init(home: String, def: TargetDef) {
        self.home = home; self.def = def
        self.dir = Engine.dropboxBase(home: home) + "/targets/" + def.id
        self.host = Engine.detectHost()
    }
    private func expand(_ p: String) -> String { p.hasPrefix("~") ? home + String(p.dropFirst()) : p }

    @discardableResult
    func sh(_ launch: String, _ args: [String], cwd: String? = nil) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (-1, "") }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }
    func log(_ m: String) { FileHandle.standardError.write(Data("[configgy] \(m)\n".utf8)) }
    private func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
    private func tsKey(_ z: String) -> String { String((z.hasSuffix(".zip") ? String(z.dropLast(4)) : z).suffix(15)) }
    private func hashDir(_ root: String) -> (String, Int) {
        var h = Insecure.SHA1(); var n = 0
        for rel in (fm.enumerator(atPath: root)?.allObjects as? [String] ?? []).sorted() {
            let p = root + "/" + rel
            var isDir: ObjCBool = false; fm.fileExists(atPath: p, isDirectory: &isDir)
            if isDir.boolValue { continue }
            n += 1; h.update(data: Data(rel.utf8)); if let d = fm.contents(atPath: p) { h.update(data: d) }
        }
        return (h.finalize().map { String(format: "%02x", $0) }.joined(), n)
    }

    // copy each existing source path into snapshot/files/<abs-without-leading-slash>
    private func stage(into tmp: String) -> Bool {
        let filesRoot = tmp + "/snapshot/files"
        var any = false
        for raw in def.paths {
            let src = expand(raw)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src, isDirectory: &isDir) else { continue }
            any = true
            let rel = src.hasPrefix("/") ? String(src.dropFirst()) : src
            let dest = filesRoot + "/" + rel
            try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if isDir.boolValue {
                var a = ["-a"]; for e in def.excludes { a.append("--exclude=\(e)") }
                a += [src + "/", dest + "/"]; _ = sh("/usr/bin/rsync", a)
            } else {
                _ = sh("/usr/bin/rsync", ["-a"] + def.excludes.map { "--exclude=\($0)" } + [src, dest])
            }
        }
        return any
    }

    func listSnapshots() -> [String] {
        guard let all = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return all.filter { $0.hasPrefix("configgy-\(def.id)-") && $0.hasSuffix(".zip") }.sorted { tsKey($0) < tsKey($1) }
    }
    func newestSnapshot() -> String? { listSnapshots().last }
    func meta(_ zip: String) -> TargetMeta? {
        let (_, s) = sh("/usr/bin/unzip", ["-p", dir + "/" + zip, "snapshot/meta.json"])
        return try? JSONDecoder().decode(TargetMeta.self, from: Data(s.utf8))
    }
    func label(_ zip: String) -> String {
        guard let m = meta(zip) else { return zip }
        return "\(m.ts.replacingOccurrences(of: "-", with: " ")) · \(m.host) · \(m.files) 個檔"
    }

    @discardableResult
    func backup() -> BackupResult {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("configgy-g-\(UUID().uuidString)")
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        guard stage(into: tmp) else { log("「\(def.name)」沒有任何存在的路徑可備份"); return .failed }
        let (hash, files) = hashDir(tmp + "/snapshot")
        if let n = newestSnapshot(), meta(n)?.hash == hash { log("「\(def.name)」沒變，略過重複備份。"); return .skipped }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = TargetMeta(host: host, ts: stamp(), iso: ISO8601DateFormatter().string(from: Date()), hash: hash, files: files)
        if let md = try? JSONEncoder().encode(m) { try? md.write(to: URL(fileURLWithPath: tmp + "/snapshot/meta.json")) }
        let name = "configgy-\(def.id)-\(host)-\(m.ts).zip"
        if sh("/usr/bin/zip", ["-rqy", dir + "/" + name, "snapshot"], cwd: tmp).0 != 0 { log("✗ 打包失敗"); return .failed }
        let all = listSnapshots()
        if all.count > keep { for old in all.prefix(all.count - keep) { try? fm.removeItem(atPath: dir + "/" + old) } }
        log("✓ 已備份「\(def.name)」→ \(name)  [\(files) 個檔]")
        return .done(name)
    }

    func previewRestore(_ zip: String) -> ChangeSet {
        let zpath = dir + "/" + zip
        guard fm.fileExists(atPath: zpath) else { return ChangeSet() }
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("configgy-gd-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: tmp) }
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        sh("/usr/bin/unzip", ["-qo", zpath, "-d", tmp])
        return ConfigDiff.compare(snapshot: tmp + "/snapshot/files", live: "")   // rel paths are absolute
    }

    @discardableResult
    func restore(_ zip: String? = nil) -> RestoreResult {
        guard let z = zip ?? newestSnapshot() else { log("「\(def.name)」還沒有備份"); return .failed }
        let zpath = dir + "/" + z
        guard fm.fileExists(atPath: zpath) else { log("找不到備份：\(z)"); return .failed }
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("configgy-gr-\(UUID().uuidString)")
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        sh("/usr/bin/unzip", ["-qo", zpath, "-d", tmp])
        let filesRoot = tmp + "/snapshot/files"
        guard fm.fileExists(atPath: filesRoot) else { log("備份內容損壞（找不到 files/）"); return .failed }
        let bk = home + "/Library/Application Support/Configgy/pre-restore/\(def.id)-\(stamp())"
        for rel in (fm.enumerator(atPath: filesRoot)?.allObjects as? [String] ?? []) {
            let sp = filesRoot + "/" + rel
            var isDir: ObjCBool = false; fm.fileExists(atPath: sp, isDirectory: &isDir)
            if isDir.boolValue { continue }
            let dst = "/" + rel
            if fm.fileExists(atPath: dst) {
                let b = bk + "/" + rel
                try? fm.createDirectory(atPath: (b as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                sh("/bin/cp", ["-p", dst, b])
            }
            try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            sh("/bin/cp", ["-p", sp, dst])
        }
        log("✓ 已還原「\(def.name)」（\(z)，舊檔備份在 \((bk as NSString).lastPathComponent)）")
        return .done(z)
    }
}
