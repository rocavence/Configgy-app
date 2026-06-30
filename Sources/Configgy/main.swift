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
    do {
        let e = try Engine()
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
    } catch {
        FileHandle.standardError.write(Data("[configgy] \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}

// ===================== GUI menubar mode =====================
enum IconState { case idle, working, success, failure }
enum OpOutcome { case success, failure, neutral }

// Native multi-select checkbox window. Must run on main. Generic — used both for
// choosing Zen workspaces and for choosing which configs to add as backup targets.
final class ModalResponder: NSObject {
    @objc func ok() { NSApp.stopModal(withCode: .OK) }
    @objc func cancel() { NSApp.stopModal(withCode: .cancel) }
}
enum CheckboxPicker {
    static func run(_ items: [(uuid: String, label: String)], title: String, prompt: String, ok okTitle: String) -> Set<String>? {
        let pad: CGFloat = 20, rowH: CGFloat = 30, width: CGFloat = 460
        let h = CGFloat(items.count) * rowH + 112
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: h),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title
        guard let content = panel.contentView else { return nil }

        let head = NSTextField(labelWithString: prompt)
        head.font = .boldSystemFont(ofSize: 13)
        head.frame = NSRect(x: pad, y: h - 44, width: width - 2 * pad, height: 20)
        content.addSubview(head)

        var checks: [NSButton] = []
        for (i, it) in items.enumerated() {
            let b = NSButton(checkboxWithTitle: it.label, target: nil, action: nil)
            b.state = .on
            b.frame = NSRect(x: pad, y: h - 74 - CGFloat(i) * rowH, width: width - 2 * pad, height: rowH)
            content.addSubview(b); checks.append(b)
        }

        let resp = ModalResponder()
        let cancel = NSButton(title: L.t("取消", "Cancel"), target: resp, action: #selector(ModalResponder.cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: width - 204, y: 16, width: 92, height: 30)
        let ok = NSButton(title: okTitle, target: resp, action: #selector(ModalResponder.ok))
        ok.bezelStyle = .rounded; ok.keyEquivalent = "\r"
        ok.frame = NSRect(x: width - 106, y: 16, width: 92, height: 30)
        content.addSubview(cancel); content.addSubview(ok)

        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        let code = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        guard code == .OK else { return nil }
        var sel = Set<String>()
        for (i, b) in checks.enumerated() where b.state == .on { sel.insert(items[i].uuid) }
        return sel
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var engine: Engine!
    var claude: ClaudeBackup!
    let q = DispatchQueue(label: "com.rocavence.configgy.engine")
    var timer: Timer?
    var wasRunning = false
    var busy = false
    var paused = false
    var fdaOK = true
    var idleRevert: DispatchWorkItem?
    let header = NSMenuItem(title: "Configgy", action: nil, keyEquivalent: "")
    let fdaItem = NSMenuItem(title: "", action: #selector(openFDAGuide), keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        do { engine = try Engine() }
        catch {
            let a = NSAlert(); a.messageText = "Configgy"; a.informativeText = error.localizedDescription
            a.runModal(); NSApp.terminate(nil); return
        }
        L.lang = L.resolve(Settings.load(engine.home).language)
        if !engine.isTest && !Engine.backupRootResolved(home: engine.home) { promptBackupFolder() }
        claude = ClaudeBackup(home: engine.home)        // created after the folder prompt so it picks up the choice
        fdaOK = engine.isTest ? true : canAccessBackup()
        engine.migrateLegacy()                          // one-time: old Apps/zennly → Apps/Configgy/zen
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.wantsLayer = true
        setIcon(.idle)
        pauseItem.target = self
        fdaItem.target = self
        buildMenu()
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

    // Dropbox not found → let the user pick a folder to store backups in.
    func promptBackupFolder() {
        let a = NSAlert()
        a.messageText = L.t("找不到 Dropbox", "Dropbox not found")
        a.informativeText = L.t("Configgy 預設備份到 Dropbox/Apps/Configgy，但這台找不到 Dropbox。請選一個資料夾存放備份。",
                                "Configgy backs up to Dropbox/Apps/Configgy by default, but no Dropbox was found here. Choose a folder to store backups.")
        a.addButton(withTitle: L.t("選擇資料夾…", "Choose Folder…"))
        a.addButton(withTitle: L.t("稍後", "Later"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = L.t("選擇備份存放資料夾", "Choose a folder to store backups")
        panel.directoryURL = URL(fileURLWithPath: engine.home)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var s = Settings.load(engine.home); s.backupBase = url.path + "/Configgy"; Settings.save(s, home: engine.home)
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

    func buildMenu() {
        let m = NSMenu(); m.delegate = self
        header.isEnabled = false
        m.addItem(header)
        fdaItem.title = L.t("⚠︎ 授予完整磁碟取用權…", "⚠︎ Grant Full Disk Access…")
        fdaItem.isHidden = fdaOK
        m.addItem(fdaItem)
        m.addItem(.separator())
        m.addItem(withTitle: L.t("備份 Zen（立即）", "Back Up Zen Now"), action: #selector(doBackup), keyEquivalent: "b").target = self
        m.addItem(withTitle: L.t("還原 Zen…（可選工作區）", "Restore Zen…"), action: #selector(doRestore), keyEquivalent: "r").target = self
        m.addItem(.separator())
        m.addItem(withTitle: L.t("備份 Claude 設定", "Back Up Claude Config"), action: #selector(doClaudeBackup), keyEquivalent: "").target = self
        m.addItem(withTitle: L.t("還原 Claude 設定", "Restore Claude Config"), action: #selector(doClaudeRestore), keyEquivalent: "").target = self
        m.addItem(.separator())
        // user-defined / discovered targets, each its own versioned backup
        for d in TargetStore.load(engine.home) {
            let sub = NSMenu()
            let b = sub.addItem(withTitle: L.t("立即備份", "Back Up Now"), action: #selector(targetBackup(_:)), keyEquivalent: ""); b.target = self; b.representedObject = d.id
            let r = sub.addItem(withTitle: L.t("還原…", "Restore…"), action: #selector(targetRestore(_:)), keyEquivalent: ""); r.target = self; r.representedObject = d.id
            sub.addItem(.separator())
            let x = sub.addItem(withTitle: L.t("移除此目標", "Remove This Target"), action: #selector(targetRemove(_:)), keyEquivalent: ""); x.target = self; x.representedObject = d.id
            let item = NSMenuItem(title: d.name, action: nil, keyEquivalent: ""); item.submenu = sub
            m.addItem(item)
        }
        m.addItem(withTitle: L.t("新增自訂備份資料夾…", "Add Custom Backup Folder…"), action: #selector(addTarget), keyEquivalent: "").target = self
        m.addItem(withTitle: L.t("掃描建議的設定…", "Scan for Configs…"), action: #selector(discoverTargets), keyEquivalent: "").target = self
        m.addItem(.separator())
        pauseItem.title = L.t("暫停 Zen 自動備份/還原", "Pause Zen Auto Backup/Restore")
        m.addItem(pauseItem)
        m.addItem(withTitle: L.t("開啟備份資料夾", "Open Backup Folder"), action: #selector(openDropbox), keyEquivalent: "").target = self
        // launch at login (default off)
        let launch = m.addItem(withTitle: L.t("開機自動啟動", "Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        // language submenu
        let langSub = NSMenu()
        let cur = Settings.load(engine.home).language
        for (code, name) in [("system", L.t("跟隨系統", "System")), ("zh", "中文"), ("en", "English")] {
            let it = langSub.addItem(withTitle: name, action: #selector(setLanguage(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = code
            it.state = ((cur ?? "system") == code) ? .on : .off
        }
        let langItem = NSMenuItem(title: L.t("語言", "Language"), action: nil, keyEquivalent: ""); langItem.submenu = langSub
        m.addItem(langItem)
        m.addItem(.separator())
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        m.addItem(withTitle: L.t("關於 Configgy（v\(ver)）", "About Configgy (v\(ver))"), action: #selector(about), keyEquivalent: "").target = self
        m.addItem(withTitle: L.t("結束 Configgy", "Quit Configgy"), action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = m
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshHeader() }
    func refreshHeader() {
        fdaOK = engine.isTest ? true : canAccessBackup()
        fdaItem.isHidden = fdaOK
        let st = engine.readState()
        let cur = st.currentZip.map { engine.label($0) } ?? L.t("尚未備份", "no backup yet")
        header.title = (fdaOK ? (engine.zenRunning() ? L.t("● Zen 開啟中", "● Zen running") : L.t("○ Zen 已關閉", "○ Zen closed"))
                              : L.t("⚠︎ 尚未授予磁碟取用權", "⚠︎ no backup access")) + (busy ? L.t("（處理中…）", " (working…)") : "")
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

        var map: [String: String] = [:]
        let labels = zips.map { z -> String in let l = engine.label(z); map[l] = z; return l }
        let listLit = "{" + labels.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ", ") + "}"
        let cancelBtn = L.t("取消", "Cancel"), wsBtn = L.t("選擇工作區", "Choose Workspaces"), fullBtn = L.t("完整還原", "Full Restore")
        let pick = "choose from list \(listLit) with title \"Configgy\" with prompt \"\(L.t("要還原哪一份備份？", "Which backup to restore?"))\" OK button name \"\(L.t("下一步", "Next"))\" cancel button name \"\(cancelBtn)\""
        let chosen = String(data: engine.sh("/usr/bin/osascript", ["-e", pick]).1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "false"
        if chosen.isEmpty || chosen == "false" { dismiss(); return .neutral }
        guard let zip = map[chosen] else { return .neutral }

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
        DispatchQueue.main.sync {
            picked = CheckboxPicker.run(wss, title: L.t("Configgy · 還原", "Configgy · Restore"),
                                        prompt: L.t("勾選要併進目前 Zen 的工作區：", "Select workspaces to merge into Zen:"),
                                        ok: L.t("還原", "Restore"))
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
        guard let zip = pickSnapshot(snaps, label: { self.claude.label($0) }, title: "Configgy · Claude") else { return .neutral }
        if !confirmChanges(claude.previewRestore(zip), title: L.t("Configgy · Claude 還原", "Configgy · Restore Claude"), what: L.t("Claude 設定", "Claude config")) { return .neutral }
        return outcome(claude.restore(zip))
    }
    // shared snapshot chooser (osascript list) used by Claude + generic restores
    func pickSnapshot(_ snaps: [String], label: (String) -> String, title: String) -> String? {
        var map: [String: String] = [:]
        let labels = snaps.map { z -> String in let l = label(z); map[l] = z; return l }
        let listLit = "{" + labels.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ", ") + "}"
        let pick = "choose from list \(listLit) with title \"\(title)\" with prompt \"\(L.t("還原哪一份？", "Which snapshot?"))\" OK button name \"\(L.t("下一步", "Next"))\" cancel button name \"\(L.t("取消", "Cancel"))\""
        let chosen = String(data: engine.sh("/usr/bin/osascript", ["-e", pick]).1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "false"
        if chosen.isEmpty || chosen == "false" { return nil }
        return map[chosen]
    }
    func info(_ msg: String) {
        _ = engine.sh("/usr/bin/osascript", ["-e", "display dialog \"\(msg)\" buttons {\"\(L.t("好","OK"))\"} default button \"\(L.t("好","OK"))\" with title \"Configgy\""])
    }

    // ---- generic targets ----
    func defFor(_ sender: Any?) -> TargetDef? {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String else { return nil }
        return TargetStore.load(engine.home).first { $0.id == id }
    }
    @objc func targetBackup(_ sender: NSMenuItem) {
        guard requireFDA(), let d = defFor(sender) else { return }
        runOp { self.outcome(GenericBackup(home: self.engine.home, def: d).backup()) }
    }
    @objc func targetRestore(_ sender: NSMenuItem) {
        guard requireFDA(), let d = defFor(sender) else { return }
        runOp { self.genericRestoreFlow(d) }
    }
    func genericRestoreFlow(_ d: TargetDef) -> OpOutcome {
        let g = GenericBackup(home: engine.home, def: d)
        let snaps = Array(g.listSnapshots().reversed())
        if snaps.isEmpty { info(L.t("「\(d.name)」還沒有備份。", "No backup for \"\(d.name)\" yet.")); return .neutral }
        guard let zip = pickSnapshot(snaps, label: { g.label($0) }, title: "Configgy · \(d.name)") else { return .neutral }
        if !confirmChanges(g.previewRestore(zip), title: "Configgy · \(d.name)", what: d.name) { return .neutral }
        return outcome(g.restore(zip))
    }
    @objc func targetRemove(_ sender: NSMenuItem) {
        guard let d = defFor(sender) else { return }
        let body = L.t("從清單移除「\(d.name)」？（雲端既有備份不會刪）", "Remove \"\(d.name)\" from the list? (existing backups are kept)")
        let ok = engine.sh("/usr/bin/osascript", ["-e", "display dialog \"\(body)\" buttons {\"\(L.t("取消","Cancel"))\",\"\(L.t("移除","Remove"))\"} default button \"\(L.t("取消","Cancel"))\" with title \"Configgy\""]).0 == 0
        if ok { TargetStore.remove(d.id, home: engine.home); buildMenu() }
    }
    @objc func addTarget() {
        guard requireFDA() else { return }
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
    @objc func discoverTargets() {
        guard requireFDA() else { return }
        let items = TargetStore.discover(engine.home)
        if items.isEmpty { info(L.t("沒找到可備份的常見設定。", "No common configs found to back up.")); return }
        let picks = items.map { (uuid: $0.id, label: $0.note.isEmpty ? $0.name : "\($0.name) · \($0.note)") }
        // each picked config becomes its own independent backup target (separate zips) — not a Zen workspace
        guard let sel = CheckboxPicker.run(picks,
                title: L.t("掃描建議的設定", "Discovered configs"),
                prompt: L.t("勾選要加入的設定（各自獨立成備份目標）：", "Select configs to add (each becomes its own target):"),
                ok: L.t("加入", "Add")), !sel.isEmpty else { return }
        var defs = TargetStore.load(engine.home)
        for it in items where sel.contains(it.id) {
            defs.removeAll { $0.id == it.id }
            defs.append(TargetDef(id: it.id, name: it.name, paths: it.paths, excludes: it.excludes))
        }
        TargetStore.save(defs, home: engine.home)
        buildMenu()
    }

    // ---- watch loop ----
    func tick() {
        if paused || busy || !fdaOK { return }       // no FDA → can't touch Dropbox; the menu warning guides the user
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
