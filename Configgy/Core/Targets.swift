import Foundation

/// Builds the targets in use from the settings: Claude Code always, Zen when
/// turned on, then each custom or suggested folder.
enum Targets {
    static func all(context: Context, settings: ConfiggySettings) -> [BackupTarget] {
        guard let base = context.base else { return [] }
        var targets: [BackupTarget] = [ClaudeTarget(context: context, base: base, keep: settings.keep)]
        if settings.zenEnabled { targets.append(ZenTarget(context: context, base: base, keep: settings.keep)) }
        for def in TargetCatalog.load(context.home) {
            targets.append(FolderTarget(context: context, base: base, def: def, keep: settings.keep, excludes: settings.folderExcludes))
        }
        return targets
    }

    static func find(_ key: String, context: Context, settings: ConfiggySettings) -> BackupTarget? {
        all(context: context, settings: settings).first { $0.key == key }
    }

    /// Picks up backups already in the folder (another Mac's, or from before a
    /// reinstall): turns Zen on if it has backups, and lists folder targets
    /// that have backups but aren't in targets.json.
    static func adoptExisting(context: Context, settings: inout ConfiggySettings) {
        guard let base = context.base else { return }
        let fm = FileManager.default
        func hasZips(_ dir: String) -> Bool { (try? fm.contentsOfDirectory(atPath: dir))?.contains { $0.hasSuffix(".zip") } ?? false }
        if !settings.zenEnabled, ZenTarget.detectProfile(home: context.home) != nil, hasZips(base + "/zen") {
            settings.zenEnabled = true
            settings.save(context.home)
        }
        guard let ids = try? fm.contentsOfDirectory(atPath: base + "/targets") else { return }
        var defs = TargetCatalog.load(context.home)
        let known = Set(defs.map(\.id))
        let found = ids.filter { !known.contains($0) && hasZips(base + "/targets/" + $0) }
        guard !found.isEmpty else { return }
        for id in found {
            defs.append(TargetCatalog.suggestions.first { $0.def.id == id }?.def ?? TargetDef(id: id, name: id, paths: []))
        }
        TargetCatalog.save(defs, home: context.home)
    }
}
