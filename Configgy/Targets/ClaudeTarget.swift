import Foundation

/// Claude Code's configuration: only what's listed here is copied from
/// ~/.claude, plus ~/.agents/skills. Logins, history, sessions, caches and
/// anything the secret filter matches are never included.
struct ClaudeTarget: BackupTarget {
    let context: Context
    let store: SnapshotStore

    let key = "claude"
    let name = "Claude Code"
    let bundleID: String? = "com.anthropic.claudefordesktop"

    /// Top-level files of ~/.claude that are configuration.
    static let files = ["settings.json", "settings.local.json", "CLAUDE.md", "keybindings.json", "statusline.sh", "statusline-command.sh"]
    /// Folders of ~/.claude copied whole (minus secrets).
    static let folders = ["agents", "commands", "skills", "hooks", "output-styles", "rules"]
    /// Plugin lists only; the plugins themselves are reinstalled from them.
    static let pluginFiles = ["plugins/installed_plugins.json", "plugins/known_marketplaces.json", "plugins/config.json"]

    init(context: Context, base: String, keep: Int) {
        self.context = context
        store = SnapshotStore(directory: base + "/claude", prefix: "configgy-claude-", host: context.host, keep: keep)
    }

    var claudeDir: String { context.home + "/.claude" }
    var agentsDir: String { context.home + "/.agents/skills" }

    /// Whether a path relative to ~/.claude belongs in the backup.
    static func includes(_ rel: String) -> Bool {
        guard !Sensitive.isSensitive(rel) else { return false }
        let parts = rel.split(separator: "/").map(String.init)
        guard let first = parts.first else { return false }
        if parts.count == 1 { return files.contains(first) }
        if folders.contains(first) { return true }
        if pluginFiles.contains(rel) { return true }
        // Each project's memory folder, and nothing else under projects/.
        return first == "projects" && parts.count >= 4 && parts[2] == "memory"
    }

    func stage(into snapshot: String) throws {
        guard FileManager.default.fileExists(atPath: claudeDir) else { throw ConfiggyError.notFound("~/.claude") }
        try FileCopy.tree(claudeDir, to: snapshot + "/claude", include: Self.includes)
        try FileCopy.tree(agentsDir, to: snapshot + "/agents-skills") { !Sensitive.isSensitive($0) }
    }

    func restorePlan(from snapshot: String) throws -> RestorePlan {
        guard FileManager.default.fileExists(atPath: snapshot + "/claude") else {
            throw ConfiggyError.badSnapshot(String(localized: "it has no claude folder"))
        }
        var plan = RestorePlan()
        // Older backups copied more than the allowlist; only allowlisted files go back.
        for rel in FileCopy.files(under: snapshot + "/claude") {
            if Self.includes(rel) {
                plan.writes.append(.init(source: snapshot + "/claude/" + rel, destination: claudeDir + "/" + rel))
            } else {
                plan.rejected.append("claude/" + rel)
            }
        }
        for rel in FileCopy.files(under: snapshot + "/agents-skills") {
            if Sensitive.isSensitive(rel) { plan.rejected.append("agents-skills/" + rel); continue }
            plan.writes.append(.init(source: snapshot + "/agents-skills/" + rel, destination: agentsDir + "/" + rel))
        }
        return plan
    }

    /// Plugins listed in the restored files, reinstalled through the `claude`
    /// command. Returns what couldn't be done, for the user to handle.
    func reinstallPlugins() -> [String] {
        guard let claude = Self.locate("claude", home: context.home) else {
            return [String(localized: "The claude command wasn't found, so plugins weren't reinstalled. Install Claude Code, then run /plugin.")]
        }
        var problems: [String] = []
        if let data = FileManager.default.contents(atPath: claudeDir + "/plugins/known_marketplaces.json"),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for value in json.values {
                guard let source = (value as? [String: Any])?["source"] as? [String: Any],
                      source["source"] as? String == "github", let repo = source["repo"] as? String else { continue }
                do { try Shell.run(claude, ["plugin", "marketplace", "add", repo]) } catch { problems.append(repo) }
            }
        }
        if let data = FileManager.default.contents(atPath: claudeDir + "/plugins/installed_plugins.json"),
           let plugins = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["plugins"] as? [String: Any] {
            for plugin in plugins.keys.sorted() {
                do { try Shell.run(claude, ["plugin", "install", plugin]) } catch { problems.append(plugin) }
            }
        }
        return problems.isEmpty ? [] : [String(localized: "These plugins didn't reinstall: \(problems.joined(separator: ", "))")]
    }

    static func locate(_ command: String, home: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", home + "/.local/bin/", home + "/.claude/local/"]
            .map { $0 + command }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
