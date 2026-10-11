#if DEBUG
import AppKit

/// End-to-end self-test driven by `scripts/selftest.sh [item]`. Everything runs
/// in a fake home with a fake cloud folder ($CONFIGGY_HOME), so no real
/// settings, Zen profile or Dropbox folder is touched. Prints PASS/FAIL lines
/// and "SELFTEST OK" when all passed. Screenshots go to $CONFIGGY_SHOTS.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var root: String { ProcessInfo.processInfo.environment["CONFIGGY_HOME"] ?? NSTemporaryDirectory() + "configgy-selftest" }
    private static var home: String { root + "/home" }
    private static var cloud: String { home + "/Dropbox/Apps/Configgy" }
    private static var context: Context { Context(home: home, base: cloud, host: "TestMac") }
    private static let fm = FileManager.default

    static func run(_ only: String) {
        Task {
            let items: [(String, () async throws -> Void)] = [
                ("secrets", secrets),
                ("retention", retention),
                ("location", location),
                ("restore", restore),
                ("scope", scope),
                ("scan", scan),
                ("corrupt", corrupt),
                ("workspaces", workspaces),
                ("status", status),
                ("windows", windows),
            ]
            for (name, test) in items where only.isEmpty || only == "all" || only == name {
                makeFixture()
                print("SELFTEST \(name)")
                do { try await test() } catch { check("\(name) threw \(error.localizedDescription)", false) }
            }
            print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: Items

    /// Credentials, tokens, venvs, sessions, cookies and passwords never reach a zip.
    private static func secrets() throws {
        let claude = ClaudeTarget(context: context, base: cloud, keep: 10)
        let zen = ZenTarget(context: context, base: cloud, keep: 10)
        _ = try BackupService.backup(claude, context: context)
        _ = try BackupService.backup(zen, context: context)
        let claudeZip = try SnapshotStore.contents(of: claude.store.newest()!.path)
        let zenZip = try SnapshotStore.contents(of: zen.store.newest()!.path)
        for bad in [".credentials.json", "api_token.txt", "agent-venv", "sessions/", "history.jsonl", "chats/"] {
            check("Claude zip has no \(bad)", !claudeZip.contains { $0.contains(bad) })
        }
        for good in ["claude/settings.json", "claude/CLAUDE.md", "claude/skills/demo/SKILL.md", "claude/projects/p1/memory/a.md", "agents-skills/tool/SKILL.md"] {
            check("Claude zip has \(good)", claudeZip.contains { $0.hasSuffix(good) })
        }
        for bad in ["cookies.sqlite", "logins.json", "key4.db", "sessionstore-backups", "formhistory"] {
            check("Zen zip has no \(bad)", !zenZip.contains { $0.contains(bad) })
        }
        check("Zen zip has prefs, CSS and restore.sh", ["profile/prefs.js", "profile/chrome/userChrome.css", "snapshot/restore.sh"].allSatisfy { p in zenZip.contains { $0.hasSuffix(p) } })
        check("an unchanged backup is skipped", try BackupService.backup(claude, context: context) == .unchanged)
        check("a sidecar describes the snapshot", claude.store.newest()?.meta?.files == 5)
    }

    /// Keep counts per machine: this Mac's oldest go, another Mac's stay.
    private static func retention() throws {
        let claude = ClaudeTarget(context: context, base: cloud, keep: 10)
        try fm.createDirectory(atPath: claude.store.directory, withIntermediateDirectories: true)
        for day in 1...12 { fm.createFile(atPath: claude.store.directory + "/configgy-claude-TestMac-202601\(String(format: "%02d", day))-120000.zip", contents: Data()) }
        for day in 1...3 { fm.createFile(atPath: claude.store.directory + "/configgy-claude-Other-Mac-202601\(String(format: "%02d", day))-120000.zip", contents: Data()) }
        _ = try BackupService.backup(claude, context: context)
        let list = claude.store.list()
        check("this Mac keeps 10", list.filter { $0.host == "TestMac" }.count == 10)
        check("another Mac's 3 are untouched", list.filter { $0.host == "Other-Mac" }.count == 3)
        check("hosts with dashes parse", list.contains { $0.host == "Other-Mac" && $0.date != nil })
        check("the newest is the new backup", list.last?.meta != nil)
    }

    /// A missing cloud folder fails loudly and leaves nothing behind.
    private static func location() throws {
        let gone = Context(home: home, base: root + "/unplugged/Configgy", host: "TestMac")
        let claude = ClaudeTarget(context: gone, base: gone.base!, keep: 10)
        var threw = false
        do { _ = try BackupService.backup(claude, context: gone) } catch { threw = true }
        check("backup to a missing folder throws", threw)
        check("nothing was created there", !fm.fileExists(atPath: root + "/unplugged"))
        check("the failure is recorded", StatusFile.load(home).results["claude"]?.ok == false)
        check("status says missing", BackupLocation.status(gone.base) == .missing(gone.base!))
    }

    /// Restore writes the snapshot back and saves what it replaced first.
    private static func restore() throws {
        let claude = ClaudeTarget(context: context, base: cloud, keep: 10)
        _ = try BackupService.backup(claude, context: context)
        let settings = home + "/.claude/settings.json"
        try Data("{\"theme\":\"changed\"}".utf8).write(to: URL(fileURLWithPath: settings))
        try Data("NEW-SECRET".utf8).write(to: URL(fileURLWithPath: home + "/.claude/.credentials.json"))
        try TempDir.with("st") { temp in
            let unpacked = try BackupService.unpack(claude.store.newest()!, into: temp)
            let plan = try claude.restorePlan(from: unpacked)
            let changes = BackupService.preview(plan)
            check("preview lists the changed file", changes.modified == [settings])
            let outcome = try BackupService.apply(plan, target: claude, label: "test", context: context)
            check("the file is restored", (try? String(contentsOfFile: settings, encoding: .utf8)) == "{\"theme\":\"dark\"}")
            check("the current login is left alone", (try? String(contentsOfFile: home + "/.claude/.credentials.json", encoding: .utf8)) == "NEW-SECRET")
            guard let pre = outcome.preRestore else { return check("a before-restore copy was saved", false) }
            let saved = try SnapshotStore.contents(of: pre.path)
            check("the before-restore copy holds the replaced file", saved.contains { $0.hasSuffix("home/.claude/settings.json") })
        }
    }

    /// Folder restores only write inside the target; old absolute paths move to this home.
    private static func scope() throws {
        let def = TargetDef(id: "shell", name: "Shell", paths: ["~/.zshrc"])
        let folder = FolderTarget(context: context, base: cloud, def: def, keep: 10, excludes: Sensitive.defaultFolderExcludes)
        try TempDir.with("scope") { temp in
            let files = temp + "/snapshot/files"
            for (rel, text) in [("Users/someoneelse/.zshrc", "old mac"), ("abs/etc/hosts", "evil"), ("home/.ssh/id_rsa", "key"), ("home/../../escape", "evil")] {
                try FileCopy.file(writeTemp(text), to: files + "/" + rel)
            }
            let plan = try folder.restorePlan(from: temp + "/snapshot")
            check("an old absolute path maps to this home", plan.writes.map(\.destination) == [home + "/.zshrc"])
            check("paths outside the target are rejected", plan.rejected.contains("abs/etc/hosts"))
            check("keys are rejected", plan.rejected.contains("home/.ssh/id_rsa"))
        }
        let archive = folder.archivePath(for: "~/.zshrc")
        check("new snapshots store paths relative to home", archive == "home/.zshrc")
    }

    /// Old backups with secrets are found and cleaned without losing the rest.
    private static func scan() throws {
        let claude = ClaudeTarget(context: context, base: cloud, keep: 10)
        try TempDir.with("legacy") { temp in
            try FileCopy.file(writeTemp("TOKEN"), to: temp + "/snapshot/claude/.credentials.json")
            try FileCopy.file(writeTemp("{}"), to: temp + "/snapshot/claude/settings.json")
            try fm.createDirectory(atPath: claude.store.directory, withIntermediateDirectories: true)
            try Shell.run("/usr/bin/zip", ["-rqy", claude.store.directory + "/configgy-claude-OldMac-20260801-090000.zip", "snapshot"], cwd: temp)
        }
        let findings = BackupService.scanForSecrets([claude], context: context)
        check("the old backup with a login is found", findings.count == 1 && findings[0].paths == ["snapshot/claude/.credentials.json"])
        try BackupService.repack(findings[0], context: context)
        let after = try SnapshotStore.contents(of: findings[0].snapshot.path)
        check("repacking removes the login", !after.contains { $0.contains("credentials") })
        check("and keeps the settings", after.contains("snapshot/claude/settings.json"))
        check("a rescan finds nothing", BackupService.scanForSecrets([claude], context: context).isEmpty)
    }

    /// Damaged zips and session files fail with an error, never a crash.
    private static func corrupt() throws {
        let claude = ClaudeTarget(context: context, base: cloud, keep: 10)
        try fm.createDirectory(atPath: claude.store.directory, withIntermediateDirectories: true)
        let bad = claude.store.directory + "/configgy-claude-TestMac-20260901-000000.zip"
        try Data("PK\u{3}\u{4}not really a zip".utf8).write(to: URL(fileURLWithPath: bad))
        var message = ""
        do { _ = try TempDir.with("bad") { try BackupService.unpack(claude.store.list().last!, into: $0) } } catch { message = error.localizedDescription }
        check("a damaged zip is refused", !message.isEmpty)
        var garbage = Data(MozLz4.magic)
        garbage += [0xff, 0xff, 0xff, 0x00, 0xf0, 0x01, 0x02]
        check("a damaged session file decodes to nothing", MozLz4.decode(garbage) == nil)
        check("random bytes decode to nothing", MozLz4.decode(Data((0..<200).map { UInt8($0 % 251) })) == nil)
        let round = MozLz4.decode(MozLz4.encode(Data(String(repeating: "zen", count: 400).utf8)))
        check("encode and decode round-trip", round == Data(String(repeating: "zen", count: 400).utf8))
    }

    /// Restoring chosen workspaces merges them into the live ones.
    private static func workspaces() throws {
        let zen = ZenTarget(context: context, base: cloud, keep: 10)
        let profile = zen.profile!
        try writeSession(profile, spaces: ["A", "B"])
        _ = try BackupService.backup(zen, context: context)
        try writeSession(profile, spaces: ["A", "C"])
        try TempDir.with("ws") { temp in
            let unpacked = try BackupService.unpack(zen.store.newest()!, into: temp)
            let listed = ZenWorkspaces.list(in: unpacked)
            check("the backup lists its workspaces", listed.map(\.label) == ["A", "B"])
            let plan = try ZenWorkspaces.mergePlan(snapshot: unpacked, profile: profile, uuids: ["uuid-B"], output: temp + "/merged")
            _ = try BackupService.apply(plan, target: zen, label: "test", context: context)
        }
        let merged = ZenWorkspaces.decode(fm.contents(atPath: profile + "/zen-sessions.jsonlz4")!)
        let names = (merged?["spaces"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        check("B joins A and C", Set(names) == ["A", "B", "C"])
    }

    /// Each target reads protected, needs attention, or failed, with a reason.
    private static func status() async throws {
        let model = AppModel(context: context)
        _ = try BackupService.backup(ClaudeTarget(context: context, base: cloud, keep: 10), context: context)
        BackupService.record("zen", ok: false, message: "zip exited with 12", context: context)
        model.refresh()
        try await Task.sleep(for: .milliseconds(600))
        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.key, $0) })
        check("Claude is protected", rows["claude"]?.health == .protected)
        check("Zen failed, with the reason", rows["zen"]?.health == .failed && rows["zen"]?.reason == "zip exited with 12")
        check("the missing folder target needs attention", rows["t:notes"]?.health == .attention)
        check("suggestions list what's on this Mac", model.suggestions.contains { $0.def.id == "git" })
    }

    /// Every window renders at its size, with a backed-up target in the list.
    private static func windows() async throws {
        _ = try BackupService.backup(ClaudeTarget(context: context, base: cloud, keep: 10), context: context)
        seedTimeline()
        let model = AppModel(context: context)
        model.refresh()
        try await Task.sleep(for: .milliseconds(500))
        let shots = ProcessInfo.processInfo.environment["CONFIGGY_SHOTS"].map { URL(fileURLWithPath: $0) }

        let main = MainWindow(model: model)
        main.show(activate: false)
        try await Task.sleep(for: .milliseconds(600))
        let mainShot = main.snapshot()
        check("the main window renders", mainShot != nil)
        save(mainShot, shots, "main")
        // A week: older backups must still show, at each lane's left edge.
        UserDefaults.standard.set(7, forKey: "Configgy.timelineRange")
        try await Task.sleep(for: .milliseconds(500))
        save(main.snapshot(), shots, "main-week")
        UserDefaults.standard.set(30, forKey: "Configgy.timelineRange")
        main.close()

        let settings = SettingsWindow(model: model)
        for page in SettingsPage.allCases {
            settings.show(page, activate: false)
            try await Task.sleep(for: .milliseconds(400))
            let image = settings.snapshot()
            check("Settings › \(page.rawValue) renders 900×600", image.map { $0.size == NSSize(width: 900, height: 600) } ?? false)
            save(image, shots, "settings-\(page.rawValue)")
        }
        settings.close()

        let onboarding = OnboardingWindow(model: model)
        onboarding.show(activate: false)
        try await Task.sleep(for: .milliseconds(400))
        let image = onboarding.snapshot()
        check("the setup guide renders", image.map { $0.size.width == 600 } ?? false)
        save(image, shots, "onboarding")
        onboarding.close()
    }

    // MARK: Fixture

    /// A fake home: ~/.claude with secrets mixed in, a Zen profile with cookies
    /// and passwords, a custom target whose files are missing, and a cloud folder.
    private static func makeFixture() {
        try? fm.removeItem(atPath: root)
        let claude = home + "/.claude"
        let files: [String: String] = [
            claude + "/settings.json": "{\"theme\":\"dark\"}",
            claude + "/CLAUDE.md": "# me",
            claude + "/.credentials.json": "SECRET",
            claude + "/history.jsonl": "history",
            claude + "/skills/demo/SKILL.md": "skill",
            claude + "/skills/demo/api_token.txt": "token",
            claude + "/skills/demo/agent-venv/lib/x.py": "venv",
            claude + "/sessions/s.json": "session",
            claude + "/projects/p1/memory/a.md": "memory",
            claude + "/projects/p1/chats/c.jsonl": "chat",
            home + "/.agents/skills/tool/SKILL.md": "agent skill",
            home + "/.gitconfig": "[user]",
            home + "/Library/Application Support/zen/installs.ini": "[Install]\nDefault=Profiles/abc.default\n",
            home + "/Library/Application Support/zen/Profiles/abc.default/prefs.js": "user_pref(\"a\", 1);",
            home + "/Library/Application Support/zen/Profiles/abc.default/chrome/userChrome.css": "css",
            home + "/Library/Application Support/zen/Profiles/abc.default/cookies.sqlite": "cookies",
            home + "/Library/Application Support/zen/Profiles/abc.default/logins.json": "passwords",
            home + "/Library/Application Support/zen/Profiles/abc.default/key4.db": "keys",
            home + "/Library/Application Support/zen/Profiles/abc.default/formhistory.sqlite": "forms",
            home + "/Library/Application Support/zen/Profiles/abc.default/sessionstore-backups/recovery.jsonlz4": "session",
        ]
        for (path, text) in files {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data(text.utf8))
        }
        try? fm.createDirectory(atPath: cloud, withIntermediateDirectories: true)
        var settings = ConfiggySettings()
        settings.backupBase = cloud
        settings.zenEnabled = true
        settings.onboarded = true
        settings.save(home)
        TargetCatalog.save([TargetDef(id: "notes", name: "Notes", paths: ["~/Notes/settings.json"])], home: home)
    }

    /// Backups spread over the past weeks from this Mac and another, so the timeline has something to show.
    private static func seedTimeline() {
        let now = Date()
        func seed(_ dir: String, _ prefix: String, _ host: String, _ daysAgo: [Double], files: Int) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for d in daysAgo {
                let date = now.addingTimeInterval(-d * 86_400)
                let ts = SnapshotStore.stamp(date)
                let path = dir + "/\(prefix)\(host)-\(ts).zip"
                fm.createFile(atPath: path, contents: Data())
                let meta = SnapshotMeta(host: host, ts: ts, iso: ISO8601DateFormatter().string(from: date), hash: UUID().uuidString, files: files)
                try? JSONEncoder().encode(meta).write(to: URL(fileURLWithPath: path + ".json"))
            }
        }
        seed(cloud + "/claude", "configgy-claude-", "TestMac", [1.2, 3.4, 6, 9.5, 13, 19, 26], files: 42)
        seed(cloud + "/claude", "configgy-claude-", "Roca-Work", [2.5, 11, 24], files: 40)
        seed(cloud + "/zen", "configgy-zen-", "TestMac", [0.6, 1.6, 2.4, 3.7, 5, 6.2, 8, 10.5, 12, 15, 17.5, 21, 23, 28], files: 318)
        seed(cloud + "/zen", "configgy-zen-", "Roca-Work", [4.2, 9, 16, 22.5], files: 305)
    }

    private static func writeSession(_ profile: String, spaces: [String]) throws {
        let json: [String: Any] = [
            "spaces": spaces.map { ["uuid": "uuid-\($0)", "name": $0, "icon": ""] },
            "tabs": spaces.map { ["zenWorkspace": "uuid-\($0)", "url": "https://\($0.lowercased()).example"] },
        ]
        try MozLz4.encode(try JSONSerialization.data(withJSONObject: json)).write(to: URL(fileURLWithPath: profile + "/zen-sessions.jsonlz4"))
    }

    private static func writeTemp(_ text: String) -> String {
        let path = NSTemporaryDirectory() + "configgy-st-\(UUID().uuidString)"
        fm.createFile(atPath: path, contents: Data(text.utf8))
        return path
    }

    private static func save(_ image: NSBitmapImageRep?, _ folder: URL?, _ name: String) {
        guard let folder, let data = image?.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private static func check(_ name: String, _ ok: Bool) {
        print(ok ? "PASS \(name)" : "FAIL \(name)")
        if !ok { failures += 1 }
    }
}
#endif
