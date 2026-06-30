import Foundation

// Configgy's Claude Code target — Swift port of claude-config-sync.
// rsync-mirrors the valuable bits of ~/.claude (+ ~/.agents/skills) to
// Apps/Configgy/claude, restores them back, and reinstalls marketplaces/plugins.
// Different mechanism from the Zen target (rsync mirror, not versioned zips).
final class ClaudeBackup {
    let home: String
    let dest: String
    let isTest = ProcessInfo.processInfo.environment["CONFIGGY_TEST"] != nil
    let fm = FileManager.default

    init(home: String) {
        self.home = home
        self.dest = Engine.dropboxBase(home: home) + "/claude/"
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

    @discardableResult
    func sh(_ launch: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (-1, "") }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }
    func log(_ m: String) { FileHandle.standardError.write(Data("[configgy] \(m)\n".utf8)) }

    // exclude rules, then keep ONLY memory/ under projects/*
    private func filterArgs() -> [String] {
        var a = excludes.map { "--exclude=\($0)" }
        a += ["--include=projects/", "--include=projects/*/", "--include=projects/*/memory/***", "--exclude=projects/*/*"]
        return a
    }

    @discardableResult
    func backup() -> BackupResult {
        guard fm.fileExists(atPath: src) else { log("找不到 ~/.claude"); return .failed }
        try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        var args = ["-a"]; args += filterArgs(); args += [src, dest]
        if sh("/usr/bin/rsync", args).0 != 0 { log("✗ rsync 備份失敗（Dropbox 權限？）"); return .failed }
        if fm.fileExists(atPath: agents) {
            _ = sh("/usr/bin/rsync", ["-a", "--exclude=.git/", agents, dest + "agents-skills/"])
        }
        let readme = "Configgy — Claude Code 設定備份\n更新：Configgy 選單『備份 Claude 設定』\n還原：選單『還原 Claude 設定』\n憑證在 macOS Keychain，不在此備份，換機需重新登入。\n"
        try? readme.write(toFile: dest + "README-backup.md", atomically: true, encoding: .utf8)
        log("✓ 已備份 Claude 設定 → \(dest)")
        return .done("claude")
    }

    @discardableResult
    func restore() -> RestoreResult {
        guard fm.fileExists(atPath: dest) else { log("Dropbox 沒有 Claude 備份"); return .failed }
        if sh("/usr/bin/rsync", ["-a", "--exclude=README-backup.md", "--exclude=agents-skills/", dest, src]).0 != 0 { return .failed }
        if fm.fileExists(atPath: dest + "agents-skills/") {
            try? fm.createDirectory(atPath: agents, withIntermediateDirectories: true)
            _ = sh("/usr/bin/rsync", ["-a", dest + "agents-skills/", agents])
        }
        if !isTest { reinstallPlugins() }
        log("✓ 已還原 Claude 設定（增量疊加，未刪本機既有檔）")
        return .done("claude")
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
