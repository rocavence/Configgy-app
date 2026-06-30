import AppKit
import ServiceManagement

// ===================== CLI mode =====================
// `Configgy backup|list|status|restore [zip]` runs headless and exits.
let args = CommandLine.arguments
if args.count > 1 {
    let cliHome = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    switch args[1] {                                   // Claude target needs no Zen profile
    case "claude-backup": ClaudeBackup(home: cliHome).backup(); exit(0)
    case "claude-restore": ClaudeBackup(home: cliHome).restore(args.count > 2 ? args[2] : nil); exit(0)
    case "claude-list":
        let c = ClaudeBackup(home: cliHome)
        for z in c.listSnapshots().reversed() { print(z); print("    " + c.label(z)) }
        exit(0)
    case "claude-preview":
        if args.count > 2 {
            let cs = ClaudeBackup(home: cliHome).previewRestore(args[2])
            print("modified: \(cs.modified.count), added: \(cs.added.count)")
            for m in cs.modified { print("  ~ \(m)") }; for a in cs.added { print("  + \(a)") }
        } else { print("Usage: Configgy claude-preview <zip>") }
        exit(0)
    case "targets":
        for d in TargetStore.load(cliHome) { print("\(d.id)\t\(d.name)\t\(d.paths.joined(separator: ", "))") }
        exit(0)
    case "discover":
        for it in TargetStore.discover(cliHome) { print("\(it.id)\t\(it.name)\t\(it.paths.joined(separator: ", "))") }
        exit(0)
    case "locations":
        print("dropbox: \(BackupLoc.dropbox(cliHome) ?? "-")")
        print("icloud:  \(BackupLoc.icloud(cliHome) ?? "-")")
        print("gdrive:  \(BackupLoc.gdrive(cliHome) ?? "-")")
        print("current: \(Engine.dropboxBase(home: cliHome))")
        exit(0)
    case "target-add":
        if args.count >= 5 { TargetStore.add(TargetDef(id: args[2], name: args[3], paths: Array(args[4...])), home: cliHome); print("added \(args[2])") }
        else { print("Usage: Configgy target-add <id> <name> <path...>") }
        exit(0)
    case "target-backup", "target-list", "target-preview", "target-restore":
        guard args.count > 2, let d = TargetStore.load(cliHome).first(where: { $0.id == args[2] }) else { print("unknown target id"); exit(1) }
        let g = GenericBackup(home: cliHome, def: d)
        switch args[1] {
        case "target-backup": g.backup()
        case "target-list": for z in g.listSnapshots().reversed() { print(z); print("    " + g.label(z)) }
        case "target-restore": g.restore(args.count > 3 ? args[3] : nil)
        default:   // target-preview
            let cs = g.previewRestore(args.count > 3 ? args[3] : (g.newestSnapshot() ?? ""))
            print("modified: \(cs.modified.count), added: \(cs.added.count)")
            for m in cs.modified { print("  ~ \(m)") }; for a in cs.added { print("  + \(a)") }
        }
        exit(0)
    default: break
    }
    let e = Engine()
    switch args[1] {
        case "backup":
            e.backup(force: args.contains("--force"))
        case "list":
            let z = Array(e.listZips().reversed())
            if z.isEmpty { e.log("雲端還沒有備份。") }
            for zz in z { print(zz); print("    " + e.label(zz)) }
        case "status":
            e.log("Profile : \(e.profileDir)")
            e.log("Dropbox : \(e.dropboxDir)")
            e.log("Host    : \(e.host)")
            e.log("Zen     : \(e.zenRunning() ? "RUNNING" : "closed")")
            e.log("目前本機對應備份 : \(e.readState().currentZip ?? "(無)")")
            e.log("雲端最新備份     : \(e.newestZip() ?? "(無)")")
        case "workspaces":
            if args.count > 2 { for w in e.workspacesIn(args[2]) { print("\(w.uuid)\t\(w.label)") } }
            else { print("Usage: Configgy workspaces <zip>") }
        case "preview":
            if args.count > 2 {
                let cs = e.previewRestore(args[2])
                print("modified: \(cs.modified.count), added: \(cs.added.count)")
                for m in cs.modified { print("  ~ \(m)") }; for a in cs.added { print("  + \(a)") }
            } else { print("Usage: Configgy preview <zip>") }
        case "restore":
            if args.count >= 5, args[3] == "ws" {
                e.restoreWorkspaces(args[2], uuids: Set(args[4...]))
            } else if args.count > 2 {
                e.restore(args[2])
            } else { e.promptRestore() }
        default:
            print("Usage: Configgy [backup|list|status|restore [zip]]")
    }
    exit(0)
}

// ===================== GUI menubar mode =====================
enum IconState { case idle, working, success, failure }
enum OpOutcome { case success, failure, neutral }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var engine: Engine!
    var claude: ClaudeBackup!
    let q = DispatchQueue(label: "com.rocavence.configgy.engine")
    var timer: Timer?
    var wasRunning = false
    var busy = false
    var paused = false
    var fdaOK = true
    var zenOn = false                          // Zen is opt-in (Settings.zenEnabled && Zen installed)
    var idleRevert: DispatchWorkItem?
    var mainWin: NSWindow?                      // unified main window
    var mainTab = 0                             // 0 = 已備份保護, 1 = 建議加入
    var mainSettings = false                    // settings page shown instead of a list
    var tabsView: CapsuleTabs?
    var toolbarHost: NSView?
    var contentHost: NSView?
    let menu = NSMenu()                       // persistent; repopulated on every open via menuNeedsUpdate
    let header = NSMenuItem(title: "Configgy", action: nil, keyEquivalent: "")
    let fdaItem = NSMenuItem(title: "", action: #selector(openFDAGuide), keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        engine = Engine()
        L.lang = L.resolve(Settings.load(engine.home).language)
        applyTheme()
        if !engine.isTest && !Engine.backupRootResolved(home: engine.home) { chooseBackupLocation(initial: true) }
        claude = ClaudeBackup(home: engine.home)        // created after the folder prompt so it picks up the choice
        zenOn = Settings.load(engine.home).zenEnabled && engine.hasZen
        fdaOK = engine.isTest ? true : canAccessBackup()
        engine.migrateLegacy()                          // one-time: old Apps/zennly → Apps/Configgy/zen
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.wantsLayer = true
        setIcon(.idle)
        pauseItem.target = self
        fdaItem.target = self
        menu.delegate = self
        statusItem.menu = menu                  // populated on demand by menuNeedsUpdate
        wasRunning = engine.zenRunning()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.tick() }
        if !fdaOK { showWelcome(firstRun: true) }       // macOS never auto-prompts for FDA — guide the user
    }

    // can we actually write into the backup folder? (Dropbox needs Full Disk Access;
    // a user-chosen plain folder just needs to be writable.)
    func canAccessBackup() -> Bool {
        let base = (engine.dropboxDir as NSString).deletingLastPathComponent   // Apps/Configgy
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let probe = base + "/.configgy-probe"
        let ok = (try? "ok".write(toFile: probe, atomically: true, encoding: .utf8)) != nil
        try? FileManager.default.removeItem(atPath: probe)
        return ok
    }

    func notFound(_ name: String) -> String? {
        info(L.t("找不到 \(name)，請改用自訂路徑。", "\(name) not found — choose a custom folder instead.")); return nil
    }
    // let the user choose where backups live: Dropbox / iCloud / Google Drive / custom
    func chooseBackupLocation(initial: Bool) {
        let home = engine.home
        let drop = BackupLoc.dropbox(home), icl = BackupLoc.icloud(home), gdr = BackupLoc.gdrive(home)
        func tag(_ s: String?) -> String { s == nil ? L.t("（未偵測到）", " (not found)") : "" }
        let custom = L.t("自訂路徑…", "Custom folder…")
        let labels = ["Dropbox\(tag(drop))", "iCloud Drive\(tag(icl))", "Google Drive\(tag(gdr))", custom]
        let listLit = "{" + labels.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
        let prompt = L.t("把備份存到哪裡？", "Where should backups be stored?")
        let pick = "choose from list \(listLit) with title \"Configgy\" with prompt \"\(prompt)\" OK button name \"\(L.t("選擇", "Choose"))\" cancel button name \"\(L.t("取消", "Cancel"))\""
        let chosen = String(data: engine.sh("/usr/bin/osascript", ["-e", pick]).1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "false"
        if chosen.isEmpty || chosen == "false" { return }
        var base: String?
        if chosen.hasPrefix("Dropbox") { base = drop ?? notFound("Dropbox") }
        else if chosen.hasPrefix("iCloud") { base = icl ?? notFound("iCloud Drive") }
        else if chosen.hasPrefix("Google") { base = gdr ?? notFound("Google Drive") }
        else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.message = L.t("選擇備份存放資料夾", "Choose a folder to store backups")
            panel.directoryURL = URL(fileURLWithPath: home)
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let u = panel.url { base = u.path + "/Configgy" }
        }
        guard let b = base else { return }
        var s = Settings.load(home); s.backupBase = b; Settings.save(s, home: home)
        if !initial { fdaOK = canAccessBackup(); buildMenu(); info(L.t("備份位置已設為：\n\(b)", "Backup location set to:\n\(b)")) }
    }

    @objc func openFDAGuide() { showWelcome(firstRun: false) }

    func showWelcome(firstRun: Bool) {
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        a.messageText = firstRun ? L.t("歡迎使用 Configgy", "Welcome to Configgy")
                                 : L.t("需要完整磁碟取用權", "Full Disk Access needed")
        a.informativeText = L.t("""
        Configgy 會把你的 Zen 與 Claude 設定備份到 Dropbox，並能跨裝置還原。

        它需要「完整磁碟取用權」才能讀寫 Dropbox 資料夾。macOS 不會自動跳出請求，請手動授權：

        1. 按「打開設定並標出 App」
        2. 在「完整磁碟取用權」清單按 ＋，選已標出的 Configgy.app
        3. 打開它的開關，選「結束並重新打開」

        授權並重開後就會開始自動備份。
        """, """
        Configgy backs up your Zen & Claude config to Dropbox and restores it across devices.

        It needs Full Disk Access to read/write the Dropbox folder. macOS never prompts for this — grant it manually:

        1. Click "Open Settings & Reveal App".
        2. In the Full Disk Access list, click +, choose the revealed Configgy.app.
        3. Toggle it on, then choose "Quit & Reopen".

        After granting and reopening, automatic backups begin.
        """)
        a.addButton(withTitle: L.t("打開設定並標出 App", "Open Settings & Reveal App"))
        a.addButton(withTitle: firstRun ? L.t("稍後", "Later") : L.t("關閉", "Close"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            let appPath = Bundle.main.bundlePath
            NSWorkspace.shared.selectFile(appPath, inFileViewerRootedAtPath: (appPath as NSString).deletingLastPathComponent)
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess") {
                NSWorkspace.shared.open(u)
            }
        }
    }

    func buildMenu() { populate(menu) }       // explicit refresh (also auto-runs on every open)
    func populate(_ m: NSMenu) {
        m.removeAllItems()
        zenOn = Settings.load(engine.home).zenEnabled && engine.hasZen
        fdaItem.title = L.t("⚠︎ 授予完整磁碟取用權…", "⚠︎ Grant Full Disk Access…")
        m.addItem(fdaItem)                       // visibility set in refreshHeader
        m.addItem(withTitle: L.t("打開 Configgy 視窗…", "Open Configgy…"), action: #selector(showMain), keyEquivalent: "o").target = self
        m.addItem(.separator())
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        m.addItem(withTitle: L.t("關於 Configgy（v\(ver)）", "About Configgy (v\(ver))"), action: #selector(about), keyEquivalent: "").target = self
        m.addItem(withTitle: L.t("結束 Configgy", "Quit Configgy"), action: #selector(quit), keyEquivalent: "q").target = self
        refreshHeader()                          // other settings live in the window's Settings page
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }   // always reflect current targets/language/state
    func refreshHeader() {
        fdaOK = engine.isTest ? true : canAccessBackup()
        fdaItem.isHidden = fdaOK
        let st = engine.readState()
        let cur = st.currentZip.map { engine.label($0) } ?? L.t("尚未備份", "no backup yet")
        let state: String
        if !fdaOK { state = L.t("⚠︎ 尚未授予磁碟取用權", "⚠︎ no backup access") }
        else if zenOn { state = engine.zenRunning() ? L.t("● Zen 開啟中", "● Zen running") : L.t("○ Zen 已關閉", "○ Zen closed") }
        else { state = "Configgy" }
        header.title = state + (busy ? L.t("（處理中…）", " (working…)") : "")
        header.toolTip = L.t("目前對應備份：\(cur)\n備份位置：\(engine.dropboxDir)", "Current backup: \(cur)\nLocation: \(engine.dropboxDir)")
        pauseItem.state = paused ? .on : .off
    }

    // ---- menubar icon state + animation ----
    func symbolImage(_ name: String, color: NSColor? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Configgy") else { return nil }
        if let color {
            let img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
            img?.isTemplate = false
            return img
        }
        base.isTemplate = true
        return base
    }
    func setIcon(_ s: IconState) {
        guard let btn = statusItem?.button else { return }
        idleRevert?.cancel()
        btn.layer?.removeAnimation(forKey: "pulse")
        switch s {
        case .idle:
            btn.image = symbolImage("externaldrive.badge.timemachine")
        case .working:
            btn.image = symbolImage("arrow.triangle.2.circlepath")
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0; a.toValue = 0.3; a.duration = 0.55
            a.autoreverses = true; a.repeatCount = .infinity
            btn.layer?.add(a, forKey: "pulse")
        case .success:
            btn.image = symbolImage("checkmark.circle.fill", color: .systemGreen)
            scheduleIdle(after: 1.8)
        case .failure:
            btn.image = symbolImage("exclamationmark.triangle.fill", color: .systemRed)
            scheduleIdle(after: 2.6)
        }
    }
    func scheduleIdle(after t: TimeInterval) {
        let w = DispatchWorkItem { [weak self] in self?.setIcon(.idle) }
        idleRevert = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }
    func outcome(_ r: BackupResult) -> OpOutcome {
        switch r { case .done: return .success; case .failed: return .failure; case .skipped: return .neutral }
    }
    func outcome(_ r: RestoreResult) -> OpOutcome {
        switch r { case .done: return .success; case .failed: return .failure; case .cancelled: return .neutral }
    }
    // run an engine op off the main thread; animate working → success/failure/idle.
    func runOp(_ op: @escaping () -> OpOutcome) {
        if busy { return }
        busy = true
        setIcon(.working); refreshHeader()
        q.async {
            let o = op()
            DispatchQueue.main.async {
                self.busy = false
                switch o {
                case .success: self.setIcon(.success)
                case .failure: self.setIcon(.failure)
                case .neutral: self.setIcon(.idle)
                }
                self.refreshHeader()
            }
        }
    }

    // ---- interactive restore (orchestrated here so the workspace step uses a native checkbox window) ----
    func interactiveRestore(autoDismiss: Bool) -> OpOutcome {
        let zips = Array(engine.listZips().reversed())   // newest first
        if zips.isEmpty { return .neutral }
        func dismiss() { if autoDismiss { var st = engine.readState(); st.dismissedZip = engine.newestZip(); engine.writeState(st) } }

        let cancelBtn = L.t("取消", "Cancel"), wsBtn = L.t("選擇工作區", "Choose Workspaces"), fullBtn = L.t("完整還原", "Full Restore")
        var pickedZip: String?
        let rows = zips.map { PickerRow(id: $0, title: engine.label($0), subtitle: "", icon: Icons.app("app.zen-browser.zen")) }
        DispatchQueue.main.sync {
            pickedZip = PickerWindow.chooseOne(title: "Configgy · Zen",
                prompt: L.t("要還原哪一份備份？", "Which backup to restore?"), items: rows, ok: L.t("下一步", "Next"))
        }
        guard let zip = pickedZip else { dismiss(); return .neutral }

        let scopeBody = L.t("要怎麼套用這份備份？\\n\\n• 完整還原：整個 Zen 設定都換成這份\\n• 選擇工作區：勾選要併進目前 Zen 的工作區",
                            "How to apply this backup?\\n\\n• Full Restore: replace the whole Zen config\\n• Choose Workspaces: merge selected workspaces into Zen")
        let scopeDialog = "display dialog \"\(scopeBody)\" buttons {\"\(cancelBtn)\", \"\(wsBtn)\", \"\(fullBtn)\"} cancel button \"\(cancelBtn)\" default button \"\(fullBtn)\" with title \"\(L.t("Configgy · 還原", "Configgy · Restore"))\""
        let (code, sd) = engine.sh("/usr/bin/osascript", ["-e", scopeDialog])
        if code != 0 { dismiss(); return .neutral }
        if !(String(data: sd, encoding: .utf8) ?? "").contains(wsBtn) {
            let cs = engine.previewRestore(zip)
            if !confirmChanges(cs, title: L.t("Configgy · 還原", "Configgy · Restore"), what: L.t("Zen 設定", "Zen config")) { dismiss(); return .neutral }
            return outcome(engine.restore(zip, scope: .full))
        }
        let wss = engine.workspacesIn(zip)
        if wss.isEmpty { return .failure }
        var picked: Set<String>?
        let wrows = wss.map { PickerRow(id: $0.uuid, title: $0.label, subtitle: "", icon: Icons.app("app.zen-browser.zen")) }
        DispatchQueue.main.sync {
            picked = PickerWindow.chooseMany(title: L.t("Configgy · 還原", "Configgy · Restore"),
                prompt: L.t("勾選要併進目前 Zen 的工作區：", "Select workspaces to merge into Zen:"), items: wrows, ok: L.t("還原", "Restore"))
        }
        guard let uuids = picked, !uuids.isEmpty else { dismiss(); return .neutral }
        return outcome(engine.restoreWorkspaces(zip, uuids: uuids))
    }

    // preview a restore's file changes and ask the user to confirm (osascript; bg-safe)
    func confirmChanges(_ cs: ChangeSet, title: String, what: String) -> Bool {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\"", with: "'") }
        let body: String
        if cs.isEmpty {
            body = L.t("這份備份與目前\(what)沒有差異。仍要套用嗎？", "This backup is identical to the current \(what). Apply anyway?")
        } else {
            let lines = cs.modified.map { "~ " + $0 } + cs.added.map { "+ " + $0 }
            let shown = lines.prefix(20).map(esc).joined(separator: "\\n")
            let more = lines.count > 20 ? L.t("\\n… 還有 \(lines.count - 20) 項", "\\n… and \(lines.count - 20) more") : ""
            body = L.t("這次會變更 \(cs.count) 個檔案（修改 \(cs.modified.count)、新增 \(cs.added.count)）：\\n\\n\(shown)\(more)\\n\\n舊檔會先備份。確定還原？",
                       "\(cs.count) file(s) will change (\(cs.modified.count) modified, \(cs.added.count) added):\\n\\n\(shown)\(more)\\n\\nOld files are backed up first. Restore?")
        }
        let d = "display dialog \"\(body)\" buttons {\"\(L.t("取消","Cancel"))\", \"\(L.t("確定還原","Restore"))\"} default button \"\(L.t("確定還原","Restore"))\" cancel button \"\(L.t("取消","Cancel"))\" with title \"\(esc(title))\""
        return engine.sh("/usr/bin/osascript", ["-e", d]).0 == 0
    }

    func claudeRestoreFlow() -> OpOutcome {
        let snaps = Array(claude.listSnapshots().reversed())   // newest first
        if snaps.isEmpty { info(L.t("Dropbox 還沒有 Claude 設定備份。", "No Claude config backup yet.")); return .neutral }
        guard let zip = pickSnapshot(snaps, label: { self.claude.label($0) }, title: "Configgy · Claude", app: "com.anthropic.claude") else { return .neutral }
        if !confirmChanges(claude.previewRestore(zip), title: L.t("Configgy · Claude 還原", "Configgy · Restore Claude"), what: L.t("Claude 設定", "Claude config")) { return .neutral }
        return outcome(claude.restore(zip))
    }
    // shared snapshot chooser — native window (icon + label rows). bg-safe (runs on main).
    func pickSnapshot(_ snaps: [String], label: (String) -> String, title: String, app: String?) -> String? {
        let icon = Icons.app(app)
        let rows = snaps.map { PickerRow(id: $0, title: label($0), subtitle: "", icon: icon) }
        var chosen: String?
        DispatchQueue.main.sync {
            chosen = PickerWindow.chooseOne(title: title, prompt: L.t("還原哪一份？", "Which snapshot?"), items: rows, ok: L.t("下一步", "Next"))
        }
        return chosen
    }
    func info(_ msg: String) {
        _ = engine.sh("/usr/bin/osascript", ["-e", "display dialog \"\(msg)\" buttons {\"\(L.t("好","OK"))\"} default button \"\(L.t("好","OK"))\" with title \"Configgy\""])
    }
    func genericRestoreFlow(_ d: TargetDef) -> OpOutcome {
        let g = GenericBackup(home: engine.home, def: d)
        let snaps = Array(g.listSnapshots().reversed())
        if snaps.isEmpty { info(L.t("「\(d.name)」還沒有備份。", "No backup for \"\(d.name)\" yet.")); return .neutral }
        guard let zip = pickSnapshot(snaps, label: { g.label($0) }, title: "Configgy · \(d.name)", app: d.app) else { return .neutral }
        if !confirmChanges(g.previewRestore(zip), title: "Configgy · \(d.name)", what: d.name) { return .neutral }
        return outcome(g.restore(zip))
    }

    // ---- generic targets ----
    func defFor(_ sender: Any?) -> TargetDef? {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String else { return nil }
        return TargetStore.load(engine.home).first { $0.id == id }
    }
    @objc func targetBackup(_ sender: NSMenuItem) { openTargetWindow(sender) }
    @objc func targetRestore(_ sender: NSMenuItem) { openTargetWindow(sender) }
    func openTargetWindow(_ sender: NSMenuItem) {        // rich window for both backup & restore
        guard let d = defFor(sender) else { return }
        let g = GenericBackup(home: engine.home, def: d)
        let icon = Icons.app(d.app)
        TargetWindow.present(
            title: d.name, icon: icon, subtitle: d.paths.joined(separator: "  ·  "),
            access: { self.engine.isTest ? true : self.canAccessBackup() },
            snapshots: { g.listSnapshots().reversed().map { PickerRow(id: $0, title: g.label($0), subtitle: "", icon: icon) } },
            backup: { g.backup() },
            preview: { g.previewRestore($0) },
            confirm: { self.confirmChanges($0, title: d.name, what: d.name) },
            restore: { g.restore($0) })
    }
    @objc func removeTargetMenu() {
        let defs = TargetStore.load(engine.home)
        if defs.isEmpty { return }
        let picks = defs.map { PickerRow(id: $0.id, title: $0.name, subtitle: $0.paths.joined(separator: ", "), icon: Icons.app($0.app)) }
        guard let sel = PickerWindow.chooseMany(
                title: L.t("移除自訂目標", "Remove Targets"),
                prompt: L.t("勾選要從清單移除的目標（雲端既有備份不會刪）：", "Select targets to remove (existing backups are kept):"),
                items: picks, ok: L.t("移除", "Remove")), !sel.isEmpty else { return }
        for id in sel { TargetStore.remove(id, home: engine.home) }
        buildMenu()
    }
    @objc func addTarget() {                 // defining a target writes only to app support — no FDA needed
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = L.t("選擇要備份的設定檔或資料夾（可多選）", "Choose config files or folders to back up (multiple allowed)")
        panel.directoryURL = URL(fileURLWithPath: engine.home)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let a = NSAlert(); a.messageText = L.t("為這個備份目標命名", "Name this backup target")
        a.addButton(withTitle: L.t("建立", "Create")); a.addButton(withTitle: L.t("取消", "Cancel"))
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.stringValue = panel.urls.first!.deletingPathExtension().lastPathComponent
        a.accessoryView = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = tf.stringValue.isEmpty ? panel.urls.first!.lastPathComponent : tf.stringValue
        let paths = panel.urls.map { u -> String in
            let s = u.path
            return s.hasPrefix(engine.home + "/") ? "~" + s.dropFirst(engine.home.count) : s
        }
        TargetStore.add(TargetDef(id: slug(name), name: name, paths: paths), home: engine.home)
        buildMenu()
    }
    func slug(_ s: String) -> String {
        let cleaned = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let j = String(cleaned).split(separator: "-").joined(separator: "-")
        return j.isEmpty ? "target-\(abs(s.hashValue) % 100000)" : j
    }
    @objc func discoverTargets() {           // scanning/adding needs no FDA; only the backup itself does
        let items = TargetStore.discover(engine.home)
        let zenSuggested = engine.hasZen && !Settings.load(engine.home).zenEnabled   // Zen is opt-in
        if items.isEmpty && !zenSuggested { info(L.t("沒找到可備份的常見設定。", "No common configs found to back up.")); return }
        // each picked config becomes its own independent backup target (separate zips)
        var picks: [PickerRow] = []
        if zenSuggested {
            picks.append(PickerRow(id: "__zen__", title: L.t("Zen 瀏覽器", "Zen Browser"),
                                   subtitle: L.t("自動備份＋跨機還原（含工作區）", "auto-backup + cross-device restore"),
                                   icon: Icons.app("app.zen-browser.zen")))
        }
        picks += items.map { PickerRow(id: $0.id, title: $0.name, subtitle: $0.note, icon: Icons.app($0.app)) }
        guard let sel = PickerWindow.chooseMany(
                title: L.t("掃描建議的設定", "Discovered Configs"),
                prompt: L.t("勾選要加入的設定（各自獨立成備份目標）：", "Select what to add (each backs up separately):"),
                items: picks, ok: L.t("加入", "Add")), !sel.isEmpty else { return }
        if sel.contains("__zen__") {
            var s = Settings.load(engine.home); s.zenEnabled = true; Settings.save(s, home: engine.home)
            zenOn = engine.hasZen
        }
        var defs = TargetStore.load(engine.home)
        for it in items where sel.contains(it.id) {
            defs.removeAll { $0.id == it.id }
            defs.append(TargetDef(id: it.id, name: it.name, paths: it.paths, excludes: it.excludes, app: it.app))
        }
        TargetStore.save(defs, home: engine.home)
        buildMenu()
    }

    // ---- watch loop ----
    func tick() {
        if paused || busy || !fdaOK || !zenOn { return }   // Zen auto-watch only when Zen is enabled & accessible
        let now = engine.zenRunning()
        if now && !wasRunning {                                   // OPEN edge
            let newest = engine.newestZip(); let st = engine.readState()
            if let nz = newest, nz != st.currentZip, nz != st.dismissedZip {
                runOp { Thread.sleep(forTimeInterval: 2); return self.interactiveRestore(autoDismiss: true) }
            }
        } else if !now && wasRunning {                            // QUIT edge
            if !FileManager.default.fileExists(atPath: engine.stateDir + "/restoring.lock") {
                runOp { self.outcome(self.engine.backup()) }
            }
        }
        wasRunning = now
    }

    // ---- actions ----
    func requireFDA() -> Bool { if fdaOK { return true }; openFDAGuide(); return false }
    @objc func doBackup() { guard requireFDA() else { return }; runOp { self.outcome(self.engine.manualBackup()) } }
    @objc func doRestore() { guard requireFDA() else { return }; runOp { self.interactiveRestore(autoDismiss: false) } }
    @objc func doClaudeBackup() { guard requireFDA() else { return }; runOp { self.outcome(self.claude.backup()) } }
    @objc func doClaudeRestore() { guard requireFDA() else { return }; runOp { self.claudeRestoreFlow() } }
    @objc func openDropbox() {
        let base = (engine.dropboxDir as NSString).deletingLastPathComponent   // Apps/Configgy
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: base))
    }
    @objc func togglePause() { paused.toggle(); refreshHeader() }
    @objc func changeBackupLocation() { chooseBackupLocation(initial: false) }
    @objc func about() { NSWorkspace.shared.open(URL(string: "https://github.com/rocavence/Configgy-app/releases")!) }
    @objc func setLanguage(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String
        var s = Settings.load(engine.home); s.language = (code == "system") ? nil : code; Settings.save(s, home: engine.home)
        L.lang = L.resolve(s.language)
        buildMenu()
    }
    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            info(L.t("無法變更開機自動啟動：\(error.localizedDescription)", "Couldn't change Launch at Login: \(error.localizedDescription)"))
        }
        buildMenu()
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
