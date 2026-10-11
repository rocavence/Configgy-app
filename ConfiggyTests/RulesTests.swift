import Foundation
import Testing
@testable import Configgy

struct SensitiveTests {
    @Test(arguments: [
        ".credentials.json", "a/b/api_token.txt", "id_rsa", "id_ed25519.pub", "keys/server.pem", ".env", ".env.local",
        "cookies.sqlite", "logins.json", "key4.db", "history.jsonl", "skills/x/.venv/lib/a.py", "x/node_modules/y.js",
        "sessionstore-backups/recovery.jsonlz4", "skills/tool/agent-venv/bin/python",
    ])
    func blocked(path: String) {
        #expect(Sensitive.isSensitive(path))
    }

    @Test(arguments: ["settings.json", "CLAUDE.md", "skills/demo/SKILL.md", "chrome/userChrome.css", "prefs.js", "projects/a/memory/notes.md"])
    func allowed(path: String) {
        #expect(!Sensitive.isSensitive(path))
    }

    @Test func folderExcludesWithTrailingSlashMatchFolders() {
        #expect(Sensitive.isExcluded("proj/.git/config", by: [".git/"]))
        #expect(!Sensitive.isExcluded(".gitconfig", by: [".git/"]))
        #expect(Sensitive.isExcluded("logs/today.log", by: ["*.log"]))
    }
}

struct AllowlistTests {
    @Test(arguments: [
        ("settings.json", true), ("CLAUDE.md", true), ("agents/a.md", true), ("skills/s/SKILL.md", true),
        ("projects/p/memory/m.md", true), ("projects/p/chat.jsonl", false), ("plugins/installed_plugins.json", true),
        ("plugins/marketplaces/x/README.md", false), ("todos/t.json", false), (".credentials.json", false), ("skills/s/.env", false),
    ])
    func claude(path: String, included: Bool) {
        #expect(ClaudeTarget.includes(path) == included)
    }

    @Test(arguments: [
        ("prefs.js", true), ("zen-sessions.jsonlz4", true), ("chrome/userChrome.css", true), ("extensions/x.xpi", true),
        ("cookies.sqlite", false), ("logins.json", false), ("sessionstore-backups/recovery.jsonlz4", false),
        ("browser-extension-data/x/storage.js", false), ("places.sqlite", false),
    ])
    func zen(path: String, included: Bool) {
        #expect(ZenTarget.includes(path) == included)
    }
}

struct SnapshotNameTests {
    let store = SnapshotStore(directory: "/tmp", prefix: "configgy-zen-", legacyPrefixes: ["zennly-"], host: "Roca-MBP")

    @Test func parsesHostsWithDashes() {
        let parsed = store.parse("configgy-zen-Roca-MBP-20261011-001500.zip")
        #expect(parsed?.host == "Roca-MBP")
        #expect(parsed?.date == SnapshotStore.date(fromStamp: "20261011-001500"))
    }

    @Test func readsLegacyNames() {
        #expect(store.parse("zennly-OldMac-20260101-120000.zip")?.host == "OldMac")
    }

    @Test func ignoresOtherFiles() {
        #expect(store.parse("configgy-zen-Roca-MBP-20261011-001500.zip.json") == nil)
        #expect(store.parse("configgy-claude-Roca-MBP-20261011-001500.zip") == nil)
        #expect(store.parse("notes.txt") == nil)
    }
}

struct ScopeTests {
    let target = FolderTarget(context: Context(home: "/Users/me", base: "/cloud", host: "Mac"),
                              base: "/cloud", def: TargetDef(id: "zed", name: "Zed", paths: ["~/.config/zed"]),
                              keep: 10, excludes: [])

    @Test func mapsNewAndOldLayouts() {
        #expect(target.destination(for: "home/.config/zed/settings.json") == "/Users/me/.config/zed/settings.json")
        #expect(target.destination(for: "Users/someone/.config/zed/settings.json") == "/Users/me/.config/zed/settings.json")
        #expect(target.destination(for: "abs/etc/hosts") == "/etc/hosts")
        #expect(target.destination(for: "home/../../etc/passwd") == nil)
    }

    @Test func onlyInsideTheTarget() {
        #expect(FolderTarget.isInside("/Users/me/.config/zed/a.json", ["/Users/me/.config/zed"]))
        #expect(FolderTarget.isInside("/Users/me/.zshrc", ["/Users/me/.zshrc"]))
        #expect(!FolderTarget.isInside("/Users/me/.config/zedx/a.json", ["/Users/me/.config/zed"]))
        #expect(!FolderTarget.isInside("/Users/me/.config/zed/../git/config", ["/Users/me/.config/zed"]))
    }

    @Test func archivesRelativeToHome() {
        #expect(target.archivePath(for: "~/.config/zed") == "home/.config/zed")
        #expect(target.archivePath(for: "/opt/tool/config") == "abs/opt/tool/config")
    }
}

struct SettingsCompatibilityTests {
    @Test func olderSettingsFilesLoadWithDefaults() throws {
        let old = #"{"backupBase":"/x/Configgy","zenEnabled":true,"uiZoom":false,"language":"zh"}"#
        let s = try JSONDecoder().decode(ConfiggySettings.self, from: Data(old.utf8))
        #expect(s.backupBase == "/x/Configgy")
        #expect(s.zenAutoBackup)
        #expect(s.keep == 10)
        #expect(s.onboarded)   // set up before the guide existed
    }

    @Test func freshInstallsAreNotOnboarded() throws {
        #expect(!(try JSONDecoder().decode(ConfiggySettings.self, from: Data("{}".utf8))).onboarded)
    }
}

struct SmallPartsTests {
    @Test func relativeTimes() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!
        #expect(RelativeTime.describe(cal.date(byAdding: .day, value: -3, to: now)!, now: now, calendar: cal).contains("3"))
        #expect(RelativeTime.describe(now, now: now, calendar: cal) != RelativeTime.describe(cal.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: cal))
    }

    @Test(arguments: [("1.0.0", "0.3.1", true), ("1.0.1", "1.0.0", true), ("1.0", "1.0.0", false), ("0.9.9", "1.0.0", false)])
    func versions(a: String, b: String, newer: Bool) {
        #expect(UpdateChecker.isNewer(a, than: b) == newer)
    }

    @Test func mozLz4RejectsTruncatedData() {
        var data = Data(MozLz4.magic)
        data += [0x10, 0x00, 0x00, 0x00, 0xf0]
        #expect(MozLz4.decode(data) == nil)
    }

    @Test func slugsAreUnique() {
        #expect(TargetCatalog.slug("My Notes!", taken: []) == "my-notes")
        #expect(TargetCatalog.slug("Git", taken: ["git"]) == "git-2")
    }
}
