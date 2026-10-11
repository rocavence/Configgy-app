import Foundation

/// A custom or suggested set of files and folders. Paths are stored relative to
/// the home folder (`~/.zshrc`), so a restore on a Mac with another user name
/// lands in the right place; a restore only ever writes inside the target's own paths.
struct TargetDef: Codable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var paths: [String]
    var excludes: [String] = []
    var app: String?

    init(id: String, name: String, paths: [String], excludes: [String] = [], app: String? = nil) {
        self.id = id
        self.name = name
        self.paths = paths
        self.excludes = excludes
        self.app = app
    }
}

struct FolderTarget: BackupTarget {
    let context: Context
    let def: TargetDef
    let store: SnapshotStore
    /// The user's folder excludes (Settings › Exclusions), on top of the target's own.
    let excludes: [String]

    var key: String { "t:\(def.id)" }
    var name: String { def.name }
    var bundleID: String? { def.app }

    init(context: Context, base: String, def: TargetDef, keep: Int, excludes: [String]) {
        self.context = context
        self.def = def
        self.excludes = excludes + def.excludes
        store = SnapshotStore(directory: base + "/targets/" + def.id, prefix: "configgy-\(def.id)-", host: context.host, keep: keep)
    }

    /// Where a path is kept inside the snapshot: `home/<path under ~>`, or `abs/<absolute path>`.
    func archivePath(for path: String) -> String {
        let expanded = context.expand(path)
        if expanded == context.home { return "home" }
        if expanded.hasPrefix(context.home + "/") { return "home/" + expanded.dropFirst(context.home.count + 1) }
        return "abs/" + expanded.drop { $0 == "/" }
    }

    func allows(_ rel: String) -> Bool {
        !Sensitive.isSensitive(rel) && !Sensitive.isExcluded(rel, by: excludes)
    }

    func stage(into snapshot: String) throws {
        var count = 0
        for path in def.paths {
            let source = context.expand(path)
            let destination = snapshot + "/files/" + archivePath(for: path)
            count += try FileCopy.tree(source, to: destination) { allows($0) }
        }
        guard count > 0 else { throw ConfiggyError.nothingToBackUp }
    }

    func restorePlan(from snapshot: String) throws -> RestorePlan {
        let root = snapshot + "/files"
        guard FileManager.default.fileExists(atPath: root) else { throw ConfiggyError.badSnapshot(String(localized: "it has no files folder")) }
        let scopes = def.paths.map(context.expand)
        var plan = RestorePlan()
        for rel in FileCopy.files(under: root) {
            guard let destination = destination(for: rel), allows(rel), Self.isInside(destination, scopes) else {
                plan.rejected.append(rel)
                continue
            }
            plan.writes.append(.init(source: root + "/" + rel, destination: destination))
        }
        return plan
    }

    /// Maps a path inside the snapshot's `files/` back to this Mac. Snapshots from
    /// before 1.0 stored absolute paths (`Users/<name>/…`); those are moved to this home.
    func destination(for rel: String) -> String? {
        let parts = rel.split(separator: "/").map(String.init)
        guard !parts.contains(".."), let first = parts.first else { return nil }
        switch first {
        case "home": return ([context.home] + parts.dropFirst()).joined(separator: "/")
        case "abs": return "/" + parts.dropFirst().joined(separator: "/")
        case "Users" where parts.count > 2: return ([context.home] + parts.dropFirst(2)).joined(separator: "/")
        default: return "/" + rel
        }
    }

    /// Whether `path` is one of `scopes` or inside one.
    static func isInside(_ path: String, _ scopes: [String]) -> Bool {
        let clean = (path as NSString).standardizingPath
        return scopes.contains { scope in
            let s = (scope as NSString).standardizingPath
            return clean == s || clean.hasPrefix(s + "/")
        }
    }
}

/// The targets you've added (~/Library/Application Support/Configgy/targets.json)
/// and the built-in list of common settings worth suggesting.
enum TargetCatalog {
    struct Suggestion: Sendable, Hashable {
        let def: TargetDef
        let note: String
    }

    static func file(_ home: String) -> String { home + "/Library/Application Support/Configgy/targets.json" }

    static func load(_ home: String) -> [TargetDef] {
        guard let data = FileManager.default.contents(atPath: file(home)) else { return [] }
        return (try? JSONDecoder().decode([TargetDef].self, from: data)) ?? []
    }

    static func save(_ defs: [TargetDef], home: String) {
        try? FileManager.default.createDirectory(atPath: (file(home) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(defs) { try? data.write(to: URL(fileURLWithPath: file(home)), options: .atomic) }
    }

    static func add(_ def: TargetDef, home: String) {
        var defs = load(home)
        defs.removeAll { $0.id == def.id }
        defs.append(def)
        save(defs, home: home)
    }

    static func remove(_ id: String, home: String) {
        save(load(home).filter { $0.id != id }, home: home)
    }

    /// A unique id from a display name.
    static func slug(_ name: String, taken: Set<String>) -> String {
        let base = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.split(separator: "-").joined(separator: "-"))
        var id = base.isEmpty ? "folder" : String(base.prefix(40))
        var n = 2
        while taken.contains(id) { id = "\(base.isEmpty ? "folder" : base)-\(n)"; n += 1 }
        return id
    }

    /// Common settings with no sync of their own. Secret files are excluded by
    /// the filter whatever is listed here.
    static let suggestions: [Suggestion] = [
        .init(def: TargetDef(id: "shell", name: String(localized: "Shell Settings"), paths: ["~/.zshrc", "~/.zprofile", "~/.zshenv", "~/.bashrc", "~/.bash_profile", "~/.profile", "~/.inputrc", "~/.aliases"]),
              note: String(localized: "Check for exported tokens in these files before adding.")),
        .init(def: TargetDef(id: "git", name: String(localized: "Git Settings"), paths: ["~/.gitconfig", "~/.gitignore_global", "~/.config/git"]), note: ""),
        .init(def: TargetDef(id: "ssh-config", name: String(localized: "SSH Config"), paths: ["~/.ssh/config"]),
              note: String(localized: "Only the config file; keys are never backed up.")),
        .init(def: TargetDef(id: "tmux", name: "tmux", paths: ["~/.tmux.conf"]), note: ""),
        .init(def: TargetDef(id: "vim", name: "Vim / Neovim", paths: ["~/.vimrc", "~/.config/nvim"]), note: ""),
        .init(def: TargetDef(id: "zed", name: "Zed", paths: ["~/.config/zed"], app: "dev.zed.Zed"), note: ""),
        .init(def: TargetDef(id: "vscode", name: "VS Code", paths: ["~/Library/Application Support/Code/User/settings.json", "~/Library/Application Support/Code/User/keybindings.json", "~/Library/Application Support/Code/User/snippets"], app: "com.microsoft.VSCode"), note: ""),
        .init(def: TargetDef(id: "terminals", name: String(localized: "Terminal Settings"), paths: ["~/.config/ghostty", "~/.config/alacritty", "~/.config/kitty", "~/.wezterm.lua"]), note: ""),
        .init(def: TargetDef(id: "starship", name: "Starship", paths: ["~/.config/starship.toml"]), note: ""),
        .init(def: TargetDef(id: "karabiner", name: "Karabiner", paths: ["~/.config/karabiner"], app: "org.pqrs.Karabiner-Elements"), note: ""),
        .init(def: TargetDef(id: "hammerspoon", name: "Hammerspoon", paths: ["~/.hammerspoon"], app: "org.hammerspoon.Hammerspoon"), note: ""),
        .init(def: TargetDef(id: "gh", name: "GitHub CLI", paths: ["~/.config/gh"], excludes: ["hosts.yml"]),
              note: String(localized: "Without hosts.yml, which holds your login.")),
        .init(def: TargetDef(id: "monitorcontrol", name: "MonitorControl", paths: ["~/Library/Preferences/app.monitorcontrol.MonitorControl.plist"], app: "app.monitorcontrol.MonitorControl"), note: ""),
        .init(def: TargetDef(id: "moom", name: "Moom", paths: ["~/Library/Preferences/com.manytricks.Moom.plist"], app: "com.manytricks.Moom"), note: ""),
        .init(def: TargetDef(id: "iina", name: "IINA", paths: ["~/Library/Preferences/com.colliderli.iina.plist"], app: "com.colliderli.iina"), note: ""),
        .init(def: TargetDef(id: "input-source-pro", name: "Input Source Pro", paths: ["~/Library/Preferences/com.runjuu.Input-Source-Pro.plist"], app: "com.runjuu.Input-Source-Pro"), note: ""),
        .init(def: TargetDef(id: "rectangle", name: "Rectangle", paths: ["~/Library/Preferences/com.knollsoft.Rectangle.plist"], app: "com.knollsoft.Rectangle"), note: ""),
        .init(def: TargetDef(id: "mac-mouse-fix", name: "Mac Mouse Fix", paths: ["~/Library/Preferences/com.nuebling.mac-mouse-fix.plist", "~/Library/Preferences/com.nuebling.mac-mouse-fix.helper.plist"], app: "com.nuebling.mac-mouse-fix"), note: ""),
        .init(def: TargetDef(id: "motrix", name: "Motrix", paths: ["~/Library/Preferences/app.motrix.native.plist"], app: "net.agalwood.Motrix"), note: ""),
        .init(def: TargetDef(id: "mole", name: "Mole", paths: ["~/Library/Preferences/com.tw93.MoleApp.plist"], app: "com.tw93.MoleApp"), note: ""),
        .init(def: TargetDef(id: "otty", name: "Otty", paths: ["~/Library/Preferences/io.appmakes.otty.plist"], app: "io.appmakes.otty"), note: ""),
        .init(def: TargetDef(id: "subler", name: "Subler", paths: ["~/Library/Preferences/org.galad.Subler.plist"], app: "org.galad.Subler"), note: ""),
        .init(def: TargetDef(id: "upscayl", name: "Upscayl", paths: ["~/Library/Preferences/org.upscayl.Upscayl.plist"], app: "org.upscayl.Upscayl"), note: ""),
        .init(def: TargetDef(id: "gamely", name: "Gamely", paths: ["~/Library/Preferences/com.gamely.app.plist"], app: "com.gamely.app"), note: ""),
    ]

    /// Suggestions whose files exist on this Mac.
    static func discover(home: String) -> [Suggestion] {
        let fm = FileManager.default
        return suggestions.filter { s in
            s.def.paths.contains { fm.fileExists(atPath: $0.hasPrefix("~/") ? home + $0.dropFirst() : $0) }
        }
    }
}
