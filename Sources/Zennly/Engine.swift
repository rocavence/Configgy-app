import Foundation
import CryptoKit

struct Summary: Codable {
    var workspaces: [String]; var tabs: Int; var pinned: Int; var essentials: Int
}
struct Meta: Codable {
    var host: String; var ts: String; var iso: String; var profileHash: String; var summary: Summary?
}
struct State: Codable {
    var lastBackupHash: String?; var currentZip: String?; var dismissedZip: String?
}

enum BackupResult { case done(String), skipped, failed }
enum RestoreResult { case done(String), cancelled, failed }

// All of Zennly's backup/restore logic. Pure Swift + a few shell-outs to
// cp/zip/unzip/pgrep/osascript/open — same approach the menubar app and the CLI share.
final class Engine {
    let home: String
    let zenRoot: String
    let profileDir: String
    let dropboxDir: String
    let stateDir: String
    let stateFile: String
    let host: String
    let keep = 10
    let isTest = ProcessInfo.processInfo.environment["ZENNLY_TEST"] != nil

    // config tier — copied only if present (mirrors zen-settings-backup)
    let files = ["prefs.js", "user.js", "zen-themes.json", "zen-keyboard-shortcuts.json",
                 "zen-boosts.jsonlz4", "zen-sessions.jsonlz4", "zen-space-routing.jsonlz4",
                 "zen-live-folders.jsonlz4", "containers.json", "xulstore.json", "search.json.mozlz4",
                 "handlers.json", "extensions.json", "addonStartup.json.lz4", "times.json",
                 "sessionCheckpoints.json", "compatibility.ini"]
    let dirs = ["chrome", "extensions", "browser-extension-data", "zen-sessions-backup", "sessionstore-backups"]

    let fm = FileManager.default

    init() throws {
        home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        zenRoot = home + "/Library/Application Support/zen"
        stateDir = home + "/Library/Application Support/zennly"
        stateFile = stateDir + "/state.json"
        host = Engine.detectHost()
        profileDir = try Engine.detectProfile(zenRoot: zenRoot)
        dropboxDir = Engine.detectDropbox(home: home)
    }

    // ---------- detection ----------
    static func detectHost() -> String {
        // localizedName = the user-set computer name ("Roca-MBP"); avoids the
        // reverse-DNS lookup ProcessInfo.hostName does (which can return junk).
        var h = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        if h.hasSuffix(".local") { h = String(h.dropLast(6)) }
        let cleaned = h.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cleaned.isEmpty ? "mac" : cleaned
    }
    static func detectProfile(zenRoot: String) throws -> String {
        let installs = zenRoot + "/installs.ini"
        if let t = try? String(contentsOfFile: installs, encoding: .utf8) {
            for line in t.split(whereSeparator: \.isNewline) where line.hasPrefix("Default=") {
                return zenRoot + "/" + line.dropFirst("Default=".count).trimmingCharacters(in: .whitespaces)
            }
        }
        let profiles = zenRoot + "/profiles.ini"
        if let t = try? String(contentsOfFile: profiles, encoding: .utf8) {
            for block in t.components(separatedBy: "\n[") where block.contains("Default=1") {
                let rel = block.contains("IsRelative=1")
                for line in block.split(whereSeparator: \.isNewline) where line.hasPrefix("Path=") {
                    let p = String(line.dropFirst("Path=".count)).trimmingCharacters(in: .whitespaces)
                    return rel ? zenRoot + "/" + p : p
                }
            }
        }
        throw NSError(domain: "Zennly", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 Zen profile（installs.ini）"])
    }
    static func detectDropbox(home: String) -> String {
        for base in [home + "/Dropbox", home + "/Library/CloudStorage/Dropbox"] {
            if FileManager.default.fileExists(atPath: base) { return base + "/Apps/zennly" }
        }
        return home + "/Library/CloudStorage/Dropbox/Apps/zennly"
    }

    // ---------- shell ----------
    @discardableResult
    func sh(_ launch: String, _ args: [String], cwd: String? = nil) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, d)
    }

    func zenRunning() -> Bool {
        if isTest { return false }
        return sh("/usr/bin/pgrep", ["-f", "Zen.app/Contents/MacOS/zen"]).0 == 0
    }

    // ---------- timestamp ----------
    func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }

    // ---------- session summary ----------
    func summarize(_ data: Data) -> Summary? {
        guard let raw = MozLz4.decode(data),
              let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        let spaces = (j["spaces"] as? [[String: Any]]) ?? []
        let tabs = (j["tabs"] as? [[String: Any]]) ?? []
        let ws = spaces.map { s -> String in
            let icon = (s["icon"] as? String) ?? ""; let name = (s["name"] as? String) ?? ""
            return "\(icon) \(name)".trimmingCharacters(in: .whitespaces)
        }
        return Summary(workspaces: ws, tabs: tabs.count,
                       pinned: tabs.filter { ($0["pinned"] as? Bool) == true }.count,
                       essentials: tabs.filter { ($0["zenEssential"] as? Bool) == true }.count)
    }

    // ---------- hashing the live profile ----------
    func profileHash() -> String {
        var h = Insecure.SHA1()
        func add(_ rel: String, _ path: String) {
            if let d = fm.contents(atPath: path) { h.update(data: Data(rel.utf8)); h.update(data: d) }
        }
        for f in files { let p = profileDir + "/" + f; if fm.fileExists(atPath: p) { add(f, p) } }
        for d in dirs {
            let root = profileDir + "/" + d
            for rel in walk(root) { add(d + "/" + rel, root + "/" + rel) }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func walk(_ root: String) -> [String] {
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        for case let p as String in en {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root + "/" + p, isDirectory: &isDir), !isDir.boolValue { out.append(p) }
        }
        return out.sorted()
    }

    // ---------- state ----------
    func readState() -> State {
        guard let d = fm.contents(atPath: stateFile), let s = try? JSONDecoder().decode(State.self, from: d)
        else { return State() }
        return s
    }
    func writeState(_ s: State) {
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: URL(fileURLWithPath: stateFile)) }
    }

    // ---------- cloud listing ----------
    // sort by the trailing YYYYMMDD-HHMMSS, NOT the whole filename — otherwise
    // a different host's backups interleave by hostname instead of by time.
    func tsKey(_ zip: String) -> String {
        let base = zip.hasSuffix(".zip") ? String(zip.dropLast(4)) : zip
        return String(base.suffix(15))
    }
    func listZips() -> [String] {
        guard let all = try? fm.contentsOfDirectory(atPath: dropboxDir) else { return [] }
        return all.filter { $0.hasPrefix("zennly-") && $0.hasSuffix(".zip") }
            .sorted { tsKey($0) < tsKey($1) }
    }
    func newestZip() -> String? { listZips().last }
    func zipMeta(_ zip: String) -> Meta? {
        let (_, d) = sh("/usr/bin/unzip", ["-p", dropboxDir + "/" + zip, "snapshot/meta.json"])
        return try? JSONDecoder().decode(Meta.self, from: d)
    }

    // ---------- backup ----------
    // Manual "Backup now": Zen must be closed for files to be finalized, so offer
    // to close it first instead of silently skipping.
    @discardableResult
    func manualBackup() -> BackupResult {
        var weClosed = false
        if zenRunning() {
            let dialog = "display dialog \"Zen 還開著。備份需要 Zen 完全關閉（設定檔關閉時才寫定）。要關閉 Zen 並備份嗎？（備份完會自動重開）\" buttons {\"取消\", \"關閉並備份\"} default button \"關閉並備份\" with title \"Zennly\" with icon note"
            if sh("/usr/bin/osascript", ["-e", dialog]).0 != 0 { return .skipped }   // cancelled
            sh("/usr/bin/osascript", ["-e", "tell application \"Zen\" to quit"])
            for _ in 0..<40 where zenRunning() { Thread.sleep(forTimeInterval: 0.5) }
            weClosed = true
        }
        let r = backup(force: true)
        if weClosed && !isTest { sh("/usr/bin/open", ["-a", "Zen"]) }   // reopen what we closed
        return r
    }

    @discardableResult
    func backup(force: Bool = false) -> BackupResult {
        if zenRunning() { log("Zen 還開著，略過備份。"); return .skipped }
        let hash = profileHash()
        var st = readState()
        if !force, st.lastBackupHash == hash { log("設定沒變，略過重複備份。"); return .skipped }

        try? fm.createDirectory(atPath: dropboxDir, withIntermediateDirectories: true)
        let ts = stamp()
        let name = "zennly-\(host)-\(ts).zip"
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("zennly-\(UUID().uuidString)")
        let stageProfile = tmp + "/snapshot/profile"
        try? fm.createDirectory(atPath: stageProfile, withIntermediateDirectories: true)
        for f in files { let s = profileDir + "/" + f; if fm.fileExists(atPath: s) { sh("/bin/cp", ["-p", s, stageProfile + "/" + f]) } }
        for d in dirs { let s = profileDir + "/" + d; if fm.fileExists(atPath: s) { sh("/bin/cp", ["-Rp", s, stageProfile + "/" + d]) } }

        var summary: Summary? = nil
        let sess = stageProfile + "/zen-sessions.jsonlz4"
        if let d = fm.contents(atPath: sess) { summary = summarize(d) }
        let iso = ISO8601DateFormatter().string(from: Date())
        let meta = Meta(host: host, ts: ts, iso: iso, profileHash: hash, summary: summary)
        if let md = try? JSONEncoder().encode(meta) { try? md.write(to: URL(fileURLWithPath: tmp + "/snapshot/meta.json")) }

        let out = dropboxDir + "/" + name
        let (code, _) = sh("/usr/bin/zip", ["-rqy", out, "snapshot"], cwd: tmp)
        try? fm.removeItem(atPath: tmp)
        if code != 0 || !fm.fileExists(atPath: out) {
            log("✗ 打包/寫入失敗（Dropbox 權限？需要 Full Disk Access）。")
            return .failed
        }

        // prune
        let all = listZips()
        if all.count > keep { for old in all.prefix(all.count - keep) { try? fm.removeItem(atPath: dropboxDir + "/" + old) } }

        st.lastBackupHash = hash; st.currentZip = name; st.dismissedZip = nil
        writeState(st)
        let tail = summary.map { "  [\($0.workspaces.joined(separator: " · ")) / \($0.tabs) 分頁]" } ?? ""
        log("✓ 已備份 → \(name)\(tail)")
        return .done(name)
    }

    // ---------- restore ----------
    @discardableResult
    func restore(_ zip: String) -> RestoreResult {
        let zpath = dropboxDir + "/" + zip
        guard fm.fileExists(atPath: zpath) else { log("找不到備份：\(zip)"); return .failed }
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let lock = stateDir + "/restoring.lock"
        try? zip.write(toFile: lock, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: lock) }

        if zenRunning() {
            log("關閉 Zen…")
            sh("/usr/bin/osascript", ["-e", "tell application \"Zen\" to quit"])
            for _ in 0..<40 where zenRunning() { Thread.sleep(forTimeInterval: 0.5) }
        }
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("zennly-r-\(UUID().uuidString)")
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        sh("/usr/bin/unzip", ["-qo", zpath, "-d", tmp])
        let src = tmp + "/snapshot/profile"
        guard fm.fileExists(atPath: src) else { log("備份內容損壞（找不到 profile/）"); return .failed }

        let bk = profileDir + "/pre-restore-backup-\(stamp())"
        try? fm.createDirectory(atPath: bk, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: src)) ?? [] {
            let dst = profileDir + "/" + name
            if fm.fileExists(atPath: dst) { sh("/bin/cp", ["-Rp", dst, bk + "/" + name]); try? fm.removeItem(atPath: dst) }
            sh("/bin/cp", ["-Rp", src + "/" + name, profileDir + "/"])
        }
        try? fm.removeItem(atPath: tmp)

        var st = readState()
        st.currentZip = zip; st.lastBackupHash = profileHash(); st.dismissedZip = nil
        writeState(st)
        log("✓ 已還原 \(zip)（舊設定備份在 \((bk as NSString).lastPathComponent)）")
        if !isTest { log("重新開啟 Zen…"); sh("/usr/bin/open", ["-a", "Zen"]) }
        return .done(zip)
    }

    // ---------- picker (native dialog via osascript; works headless & from menubar) ----------
    func label(_ zip: String) -> String {
        guard let m = zipMeta(zip) else { return zip }
        let t = m.ts
        let when = t.count >= 13
            ? "\(t.prefix(4))-\(t.dropFirst(4).prefix(2))-\(t.dropFirst(6).prefix(2)) \(t.dropFirst(9).prefix(2)):\(t.dropFirst(11).prefix(2))"
            : zip
        let tail = m.summary.map { "\($0.workspaces.joined(separator: " · ")) · \($0.tabs)分頁/\($0.essentials)essentials" } ?? ""
        return "\(when)  ·  \(m.host)  ·  \(tail)"
    }
    // shows the picker and restores the chosen zip.
    @discardableResult
    func promptRestore(autoDismiss: Bool = false) -> RestoreResult {
        let zips = listZips().reversed().map { $0 }   // newest first
        if zips.isEmpty { return .cancelled }
        var map: [String: String] = [:]
        let labels = zips.map { z -> String in let l = label(z); map[l] = z; return l }
        let listLit = "{" + labels.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ", ") + "}"
        let script = "choose from list \(listLit) with title \"Zennly\" with prompt \"雲端有較新的 Zen 備份，要還原哪一份？（會關閉並重開 Zen）\" OK button name \"還原\" cancel button name \"略過\""
        let (_, d) = sh("/usr/bin/osascript", ["-e", script])
        let chosen = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "false"
        if chosen.isEmpty || chosen == "false" {
            if autoDismiss { var st = readState(); st.dismissedZip = newestZip(); writeState(st) }
            return .cancelled
        }
        guard let zip = map[chosen] else { return .cancelled }
        return restore(zip)
    }

    func log(_ m: String) { FileHandle.standardError.write(Data("[zennly] \(m)\n".utf8)) }
}
