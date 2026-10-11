import AppKit

/// One row of the main window.
struct TargetRow: Identifiable, Sendable, Equatable {
    /// `unavailable`: nothing of it is on this Mac, so there's nothing to back up here.
    enum Health: Sendable, Equatable { case protected, attention, failed, unavailable }

    let key: String
    let name: String
    let bundleID: String?
    let health: Health
    let reason: String
    let newest: Snapshot?
    /// Every snapshot, oldest first, for the timeline.
    let snapshots: [Snapshot]
    /// Snapshots made on this Mac, and on others.
    let mine: Int
    let others: Int

    var id: String { key }
}

/// Everything the window, Settings and the menu show, and every action they
/// take. File work runs off the main actor; results come back here.
@MainActor
@Observable
final class AppModel {
    private(set) var context: Context
    private(set) var settings: ConfiggySettings
    private(set) var rows: [TargetRow] = []
    private(set) var suggestions: [TargetCatalog.Suggestion] = []
    private(set) var zenSuggested = false
    private(set) var location: BackupLocation.Status = .notChosen
    private(set) var findings: [BackupService.Finding] = []
    private(set) var busy: Set<String> = []
    /// A newer Zen backup from another Mac, offered when Zen opens.
    var zenOffer: Snapshot?
    let updates = UpdateChecker()

    /// Fired when an operation starts, succeeds or fails, for the menu-bar icon.
    @ObservationIgnored var onActivity: (Activity) -> Void = { _ in }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    enum Activity { case working, succeeded, failed, idle }

    /// Days after which a backup made on this Mac is "getting old".
    nonisolated static let staleDays = 14

    init(context: Context = .current()) {
        self.context = context
        var settings = ConfiggySettings.load(context.home)
        Targets.adoptExisting(context: context, settings: &settings)
        self.settings = settings
    }

    var targets: [BackupTarget] { Targets.all(context: context, settings: settings) }

    func target(_ key: String) -> BackupTarget? { targets.first { $0.key == key } }

    var zenInstalled: Bool { ZenTarget.detectProfile(home: context.home) != nil }

    var needsAttention: Int { rows.filter { $0.health == .attention || $0.health == .failed }.count + (location == .ok ? 0 : 1) }

    // MARK: Settings

    func updateSettings(_ change: (inout ConfiggySettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let baseChanged = s.backupBase != settings.backupBase
        settings = s
        s.save(context.home)
        if baseChanged { context = context.with(base: BackupLocation.resolve(home: context.home)) }
        refresh()
    }

    func chooseLocation(_ base: String) {
        updateSettings { $0.backupBase = base }
        var s = settings
        Targets.adoptExisting(context: context, settings: &s)
        settings = s
        refresh()
    }

    // MARK: Status

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if id == ZenTarget.bundleID { self?.zenQuit() } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if id == ZenTarget.bundleID { self?.zenLaunched() } }
        })
        refresh()
        scanForSecrets()
        updates.checkIfDue()
    }

    /// Re-reads the backup folder and rebuilds the rows, off the main actor.
    func refresh() {
        let context = context, settings = settings, findings = findings
        Task {
            let result = await Self.compute(context: context, settings: settings, findings: findings)
            location = result.location
            rows = result.rows
            suggestions = result.suggestions
            zenSuggested = result.zenSuggested
        }
    }

    private struct Computed: Sendable {
        var location: BackupLocation.Status
        var rows: [TargetRow]
        var suggestions: [TargetCatalog.Suggestion]
        var zenSuggested: Bool
    }

    @concurrent
    private static func compute(context: Context, settings: ConfiggySettings, findings: [BackupService.Finding]) async -> Computed {
        let location = BackupLocation.status(context.base)
        let status = StatusFile.load(context.home)
        let targets = Targets.all(context: context, settings: settings)
        let rows = targets.map { row(for: $0, context: context, status: status, findings: findings) }
        let used = Set(TargetCatalog.load(context.home).map(\.id))
        let suggestions = TargetCatalog.discover(home: context.home).filter { !used.contains($0.def.id) }
        let zenSuggested = !settings.zenEnabled && ZenTarget.detectProfile(home: context.home) != nil
        return Computed(location: location, rows: rows, suggestions: suggestions, zenSuggested: zenSuggested)
    }

    nonisolated static func row(for target: BackupTarget, context: Context, status: StatusFile, findings: [BackupService.Finding]) -> TargetRow {
        let all = target.store.list()
        let mine = all.filter { $0.host == context.host }
        let newest = all.last
        let secrets = findings.filter { $0.snapshot.path.hasPrefix(target.store.directory + "/") }.count
        let result = status.results[target.key]

        let health: TargetRow.Health
        let reason: String
        if let result, !result.ok {
            health = .failed
            reason = result.message ?? String(localized: "The last attempt failed.")
        } else if secrets > 0 {
            health = .attention
            reason = String(localized: "\(secrets) older backups contain secret files.")
        } else if let missing = missingReason(target, context: context) {
            health = .unavailable
            reason = missing
        } else if let last = mine.last?.date ?? (mine.isEmpty ? nil : Date.distantPast) {
            let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
            if days >= staleDays {
                health = .attention
                reason = String(localized: "Last backed up on this Mac \(days) days ago.")
            } else {
                health = .protected
                reason = String(localized: "Backed up \(RelativeTime.describe(last).lowercasedIfEnglish).")
            }
        } else {
            health = .attention
            reason = newest == nil
                ? String(localized: "Not backed up yet.")
                : String(localized: "Not backed up on this Mac yet. Other Macs have \(all.count) backups.")
        }
        return TargetRow(key: target.key, name: target.name, bundleID: target.bundleID, health: health, reason: reason,
                         newest: newest, snapshots: all, mine: mine.count, others: all.count - mine.count)
    }

    nonisolated private static func missingReason(_ target: BackupTarget, context: Context) -> String? {
        switch target {
        case let zen as ZenTarget where zen.profile == nil:
            return String(localized: "Zen isn't set up on this Mac.")
        case is ClaudeTarget where !FileManager.default.fileExists(atPath: context.home + "/.claude"):
            return String(localized: "Claude Code isn't set up on this Mac.")
        case let folder as FolderTarget where !folder.def.paths.contains(where: { FileManager.default.fileExists(atPath: context.expand($0)) }):
            return folder.def.paths.isEmpty
                ? String(localized: "Found in the backup folder; restore it to bring its files here.")
                : String(localized: "None of its files are on this Mac.")
        default:
            return nil
        }
    }

    // MARK: Backup

    /// Backs one target up. Zen must be closed: the caller asks first (see `quitZen`).
    func backup(_ key: String) async {
        guard let target = target(key), !busy.contains(key) else { return }
        busy.insert(key)
        onActivity(.working)
        let context = context
        let ok = await Task.detached { (try? BackupService.backup(target, context: context)) != nil }.value
        busy.remove(key)
        onActivity(ok ? .succeeded : .failed)
        refresh()
    }

    /// Backs up everything that can be backed up now (Zen only when it's closed).
    func backupAll() async {
        for target in targets where !(target is ZenTarget && ZenTarget.isRunning) {
            await backup(target.key)
        }
    }

    // MARK: Zen

    /// Asks Zen to quit and waits up to 20 seconds. False if it's still open.
    func quitZen() async -> Bool {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: ZenTarget.bundleID) { app.terminate() }
        for _ in 0..<40 {
            if !ZenTarget.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return !ZenTarget.isRunning
    }

    func openZen() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ZenTarget.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private var zenRestoring = false

    func setZenRestoring(_ on: Bool) { zenRestoring = on }

    private func zenQuit() {
        guard settings.zenEnabled, settings.zenAutoBackup, !zenRestoring, location == .ok else { return }
        Task { await backup("zen") }
    }

    private func zenLaunched() {
        guard settings.zenEnabled, !zenRestoring, let zen = target("zen") else { return }
        let status = StatusFile.load(context.home)
        // A newer backup made on another Mac than the one this profile matches.
        if let newest = zen.store.newest(), newest.host != context.host,
           newest.name != status.zenCurrent, newest.name != status.zenDismissed {
            zenOffer = newest
        }
    }

    func dismissZenOffer() {
        if let offer = zenOffer { StatusFile.update(context.home) { $0.zenDismissed = offer.name } }
        zenOffer = nil
    }

    // MARK: Adding and removing

    func addSuggestion(_ suggestion: TargetCatalog.Suggestion) {
        TargetCatalog.add(suggestion.def, home: context.home)
        refresh()
    }

    func addZen() { updateSettings { $0.zenEnabled = true } }

    func addFolders(_ urls: [URL], name: String) {
        let taken = Set(TargetCatalog.load(context.home).map(\.id)).union(TargetCatalog.suggestions.map(\.def.id))
        let def = TargetDef(id: TargetCatalog.slug(name, taken: taken), name: name, paths: urls.map { context.abbreviate($0.path) })
        TargetCatalog.add(def, home: context.home)
        refresh()
    }

    enum RemoveScope { case listOnly, thisMac, everywhere }

    /// Stops backing a target up. Backups are deleted only as far as asked:
    /// this Mac's, or every Mac's.
    func remove(_ key: String, scope: RemoveScope) {
        guard let target = target(key) else { return }
        let doomed = target.store.list().filter { scope == .everywhere || (scope == .thisMac && $0.host == context.host) }
        doomed.forEach(target.store.delete)
        if key == "zen" { updateSettings { $0.zenEnabled = false } }
        if let folder = target as? FolderTarget { TargetCatalog.remove(folder.def.id, home: context.home) }
        StatusFile.update(context.home) { $0.results[key] = nil }
        Log.write("Removed \(target.name) from the list" + (doomed.isEmpty ? "" : "; deleted \(doomed.count) backups"), home: context.home)
        refresh()
    }

    // MARK: Secrets in existing backups

    func scanForSecrets() {
        let targets = targets, context = context
        Task {
            findings = await Task.detached { BackupService.scanForSecrets(targets, context: context) }.value
            refresh()
        }
    }

    /// Removes the secret files from each finding's backup (the default), or deletes those backups.
    func resolveFindings(_ chosen: [BackupService.Finding], delete: Bool) async {
        let context = context
        onActivity(.working)
        let failed = await Task.detached { () -> Int in
            var failed = 0
            for finding in chosen {
                if delete { BackupService.deleteSnapshot(finding, context: context) }
                else { do { try BackupService.repack(finding, context: context) } catch { failed += 1 } }
            }
            return failed
        }.value
        findings.removeAll { chosen.contains($0) }
        onActivity(failed == 0 ? .succeeded : .failed)
        scanForSecrets()
    }

    // MARK: Folders

    func openBackupFolder() {
        guard let base = context.base else { return }
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: base))
    }

    func openLog() {
        let path = Log.file(home: context.home)
        if !FileManager.default.fileExists(atPath: path) { Log.write("Log started", home: context.home) }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Shows the app in Finder and opens Full Disk Access in System Settings.
    func openFullDiskAccess() {
        let app = Bundle.main.bundlePath
        NSWorkspace.shared.selectFile(app, inFileViewerRootedAtPath: (app as NSString).deletingLastPathComponent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess") {
            NSWorkspace.shared.open(url)
        }
    }
}
