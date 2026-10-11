import Foundation

/// `Configgy <command>`: the same backups from Terminal. Restores here apply
/// without asking (you typed the command), but still save the previous state first.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        setenv("CONFIGGY_CLI", "1", 1)
        let context = Context.current()
        var settings = ConfiggySettings.load(context.home)
        Targets.adoptExisting(context: context, settings: &settings)
        let command = args.first ?? "help"
        let rest = Array(args.dropFirst())

        do {
            switch command {
            case "backup":
                try backup(key(for: rest.first ?? "zen"), context: context, settings: settings)
            case "claude-backup":
                try backup("claude", context: context, settings: settings)
            case "target-backup":
                try backup("t:" + required(rest, 0, "target-backup <id>"), context: context, settings: settings)
            case "list", "claude-list", "target-list":
                let k = command == "list" ? key(for: rest.first ?? "zen") : command == "claude-list" ? "claude" : "t:" + (try required(rest, 0, "target-list <id>"))
                for s in try target(k, context: context, settings: settings).store.list().reversed() {
                    let when = s.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "?"
                    print("\(s.name)\n    \(when) · \(s.host)" + (s.meta.map { " · \($0.files) files" } ?? ""))
                }
            case "preview", "claude-preview", "target-preview":
                let (t, name) = try resolve(command, rest, context: context, settings: settings)
                try withPlan(t, name) { plan, _ in
                    let changes = BackupService.preview(plan)
                    print("modified: \(changes.modified.count), added: \(changes.added.count), skipped: \(changes.rejected.count)")
                    changes.modified.forEach { print("  ~ \(context.abbreviate($0))") }
                    changes.added.forEach { print("  + \(context.abbreviate($0))") }
                    changes.rejected.forEach { print("  ✗ \($0)") }
                }
            case "restore", "claude-restore", "target-restore":
                let (t, name) = try resolve(command, rest, context: context, settings: settings)
                if t is ZenTarget, ZenRunning.check() { throw ConfiggyError.appRunning("Zen") }
                let wsIndex = rest.firstIndex(of: "ws")
                try withPlan(t, name) { plan, snapshot in
                    var plan = plan
                    if let wsIndex, let zen = t as? ZenTarget, let profile = zen.profile {
                        plan = try ZenWorkspaces.mergePlan(snapshot: snapshot, profile: profile, uuids: Set(rest[(wsIndex + 1)...]),
                                                           output: (snapshot as NSString).deletingLastPathComponent + "/merged")
                    }
                    let outcome = try BackupService.apply(plan, target: t, label: name, context: context)
                    print("restored \(outcome.written) files" + (outcome.preRestore.map { "; previous state saved as \($0.name)" } ?? ""))
                }
            case "workspaces":
                let t = try target("zen", context: context, settings: settings)
                try withPlan(t, try required(rest, 0, "workspaces <zip>")) { _, snapshot in
                    for w in ZenWorkspaces.list(in: snapshot) { print("\(w.uuid)\t\(w.label)") }
                }
            case "targets":
                for t in Targets.all(context: context, settings: settings) { print("\(t.key)\t\(t.name)") }
            case "discover":
                for s in TargetCatalog.discover(home: context.home) { print("\(s.def.id)\t\(s.def.name)\t\(s.def.paths.joined(separator: ", "))") }
            case "target-add":
                guard rest.count >= 3 else { throw usage("target-add <id> <name> <path…>") }
                TargetCatalog.add(TargetDef(id: rest[0], name: rest[1], paths: rest[2...].map(context.abbreviate)), home: context.home)
                print("added \(rest[0])")
            case "locations":
                for p in BackupLocation.Provider.allCases where p != .custom {
                    print("\(p.rawValue): \(BackupLocation.detect(p, home: context.home) ?? "-")")
                }
                print("current: \(context.base ?? "-") (\(BackupLocation.status(context.base)))")
            case "scan":
                let findings = BackupService.scanForSecrets(Targets.all(context: context, settings: settings), context: context)
                if findings.isEmpty { print("no secret files found in existing backups") }
                for f in findings { print("\(f.snapshot.name)\n" + f.paths.map { "    \($0)" }.joined(separator: "\n")) }
            case "status":
                print("home:     \(context.home)\nhost:     \(context.host)\nlocation: \(context.base ?? "-")")
                for t in Targets.all(context: context, settings: settings) {
                    print("\(t.name): " + (t.store.newest()?.name ?? "no backup yet"))
                }
            default:
                print("""
                Usage: Configgy <command>
                  backup | list | preview <zip> | restore <zip> [ws <uuid…>] | workspaces <zip>   Zen
                  claude-backup | claude-list | claude-preview <zip> | claude-restore [zip]
                  targets | discover | target-add <id> <name> <path…>
                  target-backup | target-list | target-preview | target-restore <id> [zip]
                  locations | status | scan
                """)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("configgy: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func key(for word: String) -> String {
        ["zen", "claude"].contains(word) ? word : "t:" + word
    }

    private static func usage(_ text: String) -> Error {
        NSError(domain: "Configgy", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: Configgy \(text)"])
    }

    private static func required(_ args: [String], _ i: Int, _ text: String) throws -> String {
        guard args.count > i else { throw usage(text) }
        return args[i]
    }

    private static func target(_ key: String, context: Context, settings: ConfiggySettings) throws -> BackupTarget {
        if key == "zen", context.base != nil, ZenTarget.detectProfile(home: context.home) != nil {
            return ZenTarget(context: context, base: context.base!, keep: settings.keep)
        }
        guard let t = Targets.find(key, context: context, settings: settings) else { throw ConfiggyError.notFound(key) }
        return t
    }

    private static func backup(_ key: String, context: Context, settings: ConfiggySettings) throws {
        let t = try target(key, context: context, settings: settings)
        if t is ZenTarget, ZenRunning.check() { throw ConfiggyError.appRunning("Zen") }
        switch try BackupService.backup(t, context: context) {
        case .created(let s): print("backed up → \(s.name)")
        case .unchanged: print("unchanged; no new backup")
        }
    }

    /// The target and snapshot name a preview/restore command names; the newest if omitted.
    private static func resolve(_ command: String, _ rest: [String], context: Context, settings: ConfiggySettings) throws -> (BackupTarget, String) {
        if command.hasPrefix("target-") {
            let t = try target("t:" + required(rest, 0, "\(command) <id> [zip]"), context: context, settings: settings)
            return (t, rest.count > 1 ? rest[1] : try newest(t))
        }
        let t = try target(command.hasPrefix("claude") ? "claude" : "zen", context: context, settings: settings)
        return (t, try rest.first ?? newest(t))
    }

    private static func newest(_ t: BackupTarget) throws -> String {
        guard let s = t.store.newest() else { throw ConfiggyError.notFound(String(localized: "a backup")) }
        return s.name
    }

    private static func withPlan(_ t: BackupTarget, _ name: String, _ body: (RestorePlan, String) throws -> Void) throws {
        guard let snapshot = t.store.list().first(where: { $0.name == name }) else { throw ConfiggyError.notFound(name) }
        try TempDir.with("cli") { temp in
            let root = try BackupService.unpack(snapshot, into: temp)
            try body(try t.restorePlan(from: root), root)
        }
    }
}

/// Whether Zen is running, without AppKit's main-thread requirements.
enum ZenRunning {
    static func check() -> Bool {
        if ProcessInfo.processInfo.environment["CONFIGGY_HOME"] != nil { return false }
        return Shell.succeeds("/usr/bin/pgrep", ["-f", "Zen.app/Contents/MacOS/zen"])
    }
}
