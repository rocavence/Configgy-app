import Foundation
import CryptoKit

struct ClaudeMeta: Codable { let host: String; let ts: String; let iso: String; let hash: String; let files: Int }

// Configgy's Claude Code target — versioned zip snapshots of the valuable bits of
// ~/.claude (+ ~/.agents/skills), so history & rollback work (like the Zen target).
// Excludes sessions/caches/git clones. Restore is additive and reinstalls
// marketplaces/plugins. Manual only.
final class ClaudeBackup {
    let home: String
    let dir: String          // Apps/Configgy/claude  (folder of snapshot zips)
    let host: String
    let keep = 10
    let isTest = ProcessInfo.processInfo.environment["CONFIGGY_TEST"] != nil
    let fm = FileManager.default

    init(home: String) {
        self.home = home
        self.dir = Engine.dropboxBase(home: home) + "/claude"
        self.host = Engine.detectHost()
    }
    var src: String { home + "/.claude/" }
    var agents: String { home + "/.agents/skills/" }

    // sensitive (sessions), noisy (cache), or rebuildable (git clones) — excluded.
    private let excludes = [
        ".git/", "backups/", "cache/", "image-cache/", "paste-cache/", "file-history/",
        "shell-snapshots/", "session-env/", "sessions/", "telemetry/", "tasks/", "plans/",
        "plugins/marketplaces/", "plugins/data/", "plugins/repos/", "daemon/",
        "history.jsonl", ".last-cleanup", ".last-update-result.json", "mcp-needs-auth-cache.json",
    ]
    private func filterArgs() -> [String] {
        var a = excludes.map { "--exclude=\($0)" }
        a += ["--include=projects/", "--include=projects/*/", "--include=projects/*/memory/***", "--exclude=projects/*/*"]
        return a
    }

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
    private func tsKey(_ zip: String) -> String { String((zip.hasSuffix(".zip") ? String(zip.dropLast(4)) : zip).suffix(15)) }

    // rsync the config-tier subset into a staging dir.
    private func stage(into tmp: String) -> Bool {
        let stageClaude = tmp + "/snapshot/claude"
        try? fm.createDirectory(atPath: stageClaude, withIntermediateDirectories: true)
        var a = ["-a"]; a += filterArgs(); a += [src, stageClaude + "/"]
        if sh("/usr/bin/rsync", a).0 != 0 { return false }
        if fm.fileExists(atPath: agents) {
            _ = sh("/usr/bin/rsync", ["-a", "--exclude=.git/", agents, tmp + "/snapshot/agents-skills/"])
        }
        return true
    }
    private func hashDir(_ root: String) -> (String, Int) {
        var h = Insecure.SHA1(); var n = 0
        let files = (fm.enumerator(atPath: root)?.allObjects as? [String] ?? []).sorted()
        for rel in files {
            let p = root + "/" + rel
            var isDir: ObjCBool = false; fm.fileExists(atPath: p, isDirectory: &isDir)
            if isDir.boolValue { continue }
            n += 1
            h.update(data: Data(rel.utf8))
            if let d = fm.contents(atPath: p) { h.update(data: d) }
        }
        return (h.finalize().map { String(format: "%02x", $0) }.joined(), n)
    }

    func listSnapshots() -> [String] {
        guard let all = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return all.filter { $0.hasPrefix("configgy-claude-") && $0.hasSuffix(".zip") }.sorted { tsKey($0) < tsKey($1) }
    }
    func newestSnapshot() -> String? { listSnapshots().last }
    func meta(_ zip: String) -> ClaudeMeta? {
        let (_, s) = sh("/usr/bin/unzip", ["-p", dir + "/" + zip, "snapshot/meta.json"])
        return try? JSONDecoder().decode(ClaudeMeta.self, from: Data(s.utf8))
    }
    func label(_ zip: String) -> String {
        guard let m = meta(zip) else { return zip }
        let t = m.ts.replacingOccurrences(of: "-", with: " ")
        return "\(t) · \(m.host) · \(m.files) 個檔"
    }

    @discardableResult
    func backup() -> BackupResult {
        guard fm.fileExists(atPath: src) else { log("找不到 ~/.claude"); return .failed }
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("configgy-c-\(UUID().uuidString)")
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        guard stage(into: tmp) else { log("✗ rsync 暫存失敗（Dropbox/權限？）"); return .failed }

        let (hash, files) = hashDir(tmp + "/snapshot")
        if let newest = newestSnapshot(), meta(newest)?.hash == hash { log("Claude 設定沒變，略過重複備份。"); return .skipped }

        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter().string(from: Date())
        let m = ClaudeMeta(host: host, ts: stamp(), iso: iso, hash: hash, files: files)
        if let md = try? JSONEncoder().encode(m) { try? md.write(to: URL(fileURLWithPath: tmp + "/snapshot/meta.json")) }
        let name = "configgy-claude-\(host)-\(m.ts).zip"
        if sh("/usr/bin/zip", ["-rqy", dir + "/" + name, "snapshot"], cwd: tmp).0 != 0 { log("✗ 打包失敗"); return .failed }
        let all = listSnapshots()
        if all.count > keep { for old in all.prefix(all.count - keep) { try? fm.removeItem(atPath: dir + "/" + old) } }
        log("✓ 已備份 Claude 設定 → \(name)  [\(files) 個檔]")
        return .done(name)
    }

    // what a restore of `zip` would change in the live ~/.claude (+ agents)
    func previewRestore(_ zip: String) -> ChangeSet {
        let zpath = dir + "/" + zip
        guard fm.fileExists(atPath: zpath) else { return ChangeSet() }
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("configgy-cd-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: tmp) }
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        sh("/usr/bin/unzip", ["-qo", zpath, "-d", tmp])
        var cs = ConfigDiff.compare(snapshot: tmp + "/snapshot/claude", live: home + "/.claude")
        let ags = ConfigDiff.compare(snapshot: tmp + "/snapshot/agents-skills", live: home + "/.agents/skills")
        cs.modified += ags.modified.map { "agents-skills/" + $0 }
        cs.added += ags.added.map { "agents-skills/" + $0 }
        return cs
    }

    @discardableResult
    func restore(_ zip: String? = nil) -> RestoreResult {
        guard let z = zip ?? newestSnapshot() else { log("Dropbox 沒有 Claude 備份"); return .failed }
        let zpath = dir + "/" + z
        guard fm.fileExists(atPath: zpath) else { log("找不到備份：\(z)"); return .failed }
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("configgy-cr-\(UUID().uuidString)")
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        sh("/usr/bin/unzip", ["-qo", zpath, "-d", tmp])
        let stagedClaude = tmp + "/snapshot/claude/"
        guard fm.fileExists(atPath: stagedClaude) else { log("備份內容損壞（找不到 claude/）"); return .failed }
        if sh("/usr/bin/rsync", ["-a", stagedClaude, src]).0 != 0 { return .failed }   // additive, no --delete
        let stagedAgents = tmp + "/snapshot/agents-skills/"
        if fm.fileExists(atPath: stagedAgents) {
            try? fm.createDirectory(atPath: agents, withIntermediateDirectories: true)
            _ = sh("/usr/bin/rsync", ["-a", stagedAgents, agents])
        }
        if !isTest { reinstallPlugins() }
        log("✓ 已還原 Claude 設定（\(z)，增量疊加未刪本機既有檔）")
        return .done(z)
    }

    private func locate(_ cmd: String) -> String? {
        for p in ["/opt/homebrew/bin/\(cmd)", "/usr/local/bin/\(cmd)", home + "/.local/bin/\(cmd)"] {
            if fm.isExecutableFile(atPath: p) { return p }
        }
        let (c, out) = sh("/usr/bin/env", ["which", cmd])
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return c == 0 && !s.isEmpty ? s : nil
    }
    private func reinstallPlugins() {
        if let claude = locate("claude") {
            if let d = fm.contents(atPath: home + "/.claude/plugins/known_marketplaces.json"),
               let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                for (_, v) in j {
                    if let vv = v as? [String: Any], let s = vv["source"] as? [String: Any],
                       s["source"] as? String == "github", let repo = s["repo"] as? String {
                        _ = sh(claude, ["plugin", "marketplace", "add", repo])
                    }
                }
            }
            if let d = fm.contents(atPath: home + "/.claude/plugins/installed_plugins.json"),
               let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let plugins = j["plugins"] as? [String: Any] {
                for k in plugins.keys { _ = sh(claude, ["plugin", "install", k]) }
            }
        }
        if let brew = locate("brew") { _ = sh(brew, ["install", "quarkdown"]) }
    }
}
