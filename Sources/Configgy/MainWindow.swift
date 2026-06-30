import AppKit
import ServiceManagement

// Unified main window: a capsule tab switches between "已備份保護" (active targets)
// and "建議加入" (suggestions); a gear opens an in-window Settings page. Per-tab
// toolbars. Scales via UI. Mole-style dark list with custom pill buttons.
extension AppDelegate {
    struct Entry { let id: String; let name: String; let icon: NSImage; let detail: String; let suggestion: Bool }

    @objc func showMain() {
        if mainWin == nil { buildMainWindow() }
        adoptExistingBackups()                      // scan the backup folder; surface anything already backed up
        refreshMain()
        NSApp.setActivationPolicy(.regular)
        mainWin?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == mainWin { NSApp.setActivationPolicy(.accessory) }
    }

    private func buildMainWindow() {
        let w = UI.s(760), h = UI.s(560)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = "Configgy"; win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true; win.titlebarSeparatorStyle = .none   // seamless: no distinct title bar shade
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false          // we manage its lifetime; closing must not free it underneath an event
        win.minSize = NSSize(width: UI.s(640), height: UI.s(420))
        let bg = BackdropView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .underWindowBackground; bg.blendingMode = .behindWindow; bg.state = .active
        bg.autoresizingMask = [.width, .height]; win.contentView = bg

        let headerH = UI.s(132)                   // title strip + big title + whitespace + tabs row
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h - headerH))
        content.autoresizingMask = [.width, .height]; bg.addSubview(content); contentHost = content

        let toolbar = NSView(frame: NSRect(x: 0, y: h - headerH, width: w, height: headerH))
        toolbar.autoresizingMask = [.width, .minYMargin]; bg.addSubview(toolbar); toolbarHost = toolbar

        // big title + small version (left, below the traffic-light strip)
        let title = NSTextField(labelWithString: "Configgy")
        title.font = UI.font(30, .bold); title.sizeToFit()
        title.setFrameOrigin(NSPoint(x: UI.s(22), y: h - UI.s(72)))
        title.autoresizingMask = [.minYMargin]; bg.addSubview(title)
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let vlabel = NSTextField(labelWithString: "v\(ver)")
        vlabel.font = UI.font(11.5, .medium); vlabel.textColor = .tertiaryLabelColor; vlabel.sizeToFit()
        vlabel.setFrameOrigin(NSPoint(x: title.frame.maxX + UI.s(8), y: title.frame.minY + UI.s(6)))
        vlabel.autoresizingMask = [.minYMargin]; bg.addSubview(vlabel)

        let tabs = CapsuleTabs(titles: [L.t("已備份保護", "Protected"), L.t("建議加入", "Suggestions")])
        tabs.onSelect = { [weak self] i in self?.mainTab = i; self?.mainSettings = false; self?.refreshMain() }
        tabs.setFrameOrigin(NSPoint(x: UI.s(20), y: h - UI.s(120)))   // tabs row, with whitespace below the title
        tabs.autoresizingMask = [.maxXMargin, .minYMargin]
        bg.addSubview(tabs); tabsView = tabs       // added last → above the toolbar layer

        win.delegate = self
        mainWin = win
    }

    func refreshMain() {
        guard let toolbar = toolbarHost, let content = contentHost else { return }
        tabsView?.select(mainSettings ? -1 : mainTab)
        toolbar.subviews.forEach { $0.removeFromSuperview() }
        content.subviews.forEach { $0.removeFromSuperview() }

        // right-aligned toolbar buttons (rightmost first)
        var tx = toolbar.bounds.width - UI.s(20)
        let btnY = UI.s(14)                            // align with the tabs row (bottom of the header host)
        func tool(_ sym: String, _ t: String, _ act: @escaping () -> Void) {
            let b = PillButton(symbol: sym, title: t); b.onClick = act
            tx -= b.frame.width
            b.setFrameOrigin(NSPoint(x: tx, y: btnY))
            b.autoresizingMask = [.minXMargin]; toolbar.addSubview(b); tx -= UI.s(8)
        }
        if mainSettings {
            tool("xmark", L.t("關閉", "Close")) { [weak self] in self?.mainSettings = false; self?.refreshMain() }
        } else if mainTab == 0 {
            tool("gearshape", L.t("設定", "Settings")) { [weak self] in self?.mainSettings = true; self?.refreshMain() }
            tool("folder", L.t("備份資料夾", "Backup Folder")) { [weak self] in self?.openDropbox() }
        } else {
            tool("folder.badge.plus", L.t("加入自訂備份", "Add Custom")) { [weak self] in self?.addFolderFromMain() }
            tool("arrow.clockwise", L.t("重新掃描", "Rescan")) { [weak self] in self?.refreshMain() }
        }

        if mainSettings { buildSettings(in: content) }
        else { buildList(in: content, suggestions: mainTab == 1) }
    }

    // ---- lists ----
    private func buildList(in host: NSView, suggestions: Bool) {
        let items = entries().filter { $0.suggestion == suggestions }
        let scroll = NSScrollView(frame: host.bounds.insetBy(dx: 0, dy: 0))
        scroll.frame = NSRect(x: UI.s(16), y: UI.s(16), width: host.bounds.width - UI.s(32), height: host.bounds.height - UI.s(24))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autoresizingMask = [.width, .height]
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true   // only on scroll, auto-hide when idle
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: scroll.frame.width, height: 0)); doc.autoresizingMask = [.width]
        let rowH = UI.s(60); var y = UI.s(4)
        if items.isEmpty {
            let empty = NSTextField(labelWithString: suggestions ? L.t("沒有可建議的設定。按「重新掃描」再試。", "No suggestions. Try Rescan.")
                                                                 : L.t("還沒有備份目標。到「建議加入」加一個。", "No targets yet. Add one under Suggestions."))
            empty.font = UI.font(12); empty.textColor = .tertiaryLabelColor
            empty.frame = NSRect(x: UI.s(18), y: UI.s(14), width: scroll.frame.width - UI.s(36), height: UI.s(18)); doc.addSubview(empty)
            y = UI.s(48)
        }
        for it in items { doc.addSubview(makeMainRow(it, y: y, width: scroll.frame.width, rowH: rowH)); y += rowH + UI.s(6) }
        doc.frame = NSRect(x: 0, y: 0, width: scroll.frame.width, height: max(y + UI.s(6), 1))
        scroll.documentView = doc; host.addSubview(scroll)
    }

    // scan Apps/Configgy for folders that already contain backups, and surface them
    // under 已備份保護 (re-adopt Zen + targets even if not in local settings/targets.json).
    private func adoptExistingBackups() {
        let fm = FileManager.default
        func hasZips(_ dir: String) -> Bool { (try? fm.contentsOfDirectory(atPath: dir))?.contains { $0.hasSuffix(".zip") } ?? false }
        let base = Engine.dropboxBase(home: engine.home)
        if engine.hasZen && !Settings.load(engine.home).zenEnabled && hasZips(base + "/zen") {
            var s = Settings.load(engine.home); s.zenEnabled = true; Settings.save(s, home: engine.home); zenOn = true
        }
        guard let ids = try? fm.contentsOfDirectory(atPath: base + "/targets") else { return }
        var defs = TargetStore.load(engine.home)
        let have = Set(defs.map { $0.id })
        var changed = false
        for id in ids where !have.contains(id) && hasZips(base + "/targets/" + id) {
            if let cat = TargetStore.catalog.first(where: { $0.id == id }) {
                defs.append(TargetDef(id: cat.id, name: cat.name, paths: cat.paths, excludes: cat.excludes, app: cat.app))
            } else {
                defs.append(TargetDef(id: id, name: id, paths: []))   // restore-only (paths unknown locally)
            }
            changed = true
        }
        if changed { TargetStore.save(defs, home: engine.home) }
    }

    private func entries() -> [Entry] {
        var out: [Entry] = []
        out.append(Entry(id: "claude", name: "Claude Code", icon: Icons.app("com.anthropic.claude"), detail: claudeDetail(), suggestion: false))
        if zenOn { out.append(Entry(id: "zen", name: "Zen Browser", icon: Icons.app("app.zen-browser.zen"), detail: zenDetail(), suggestion: false)) }
        let defs = TargetStore.load(engine.home)
        for d in defs {
            let g = GenericBackup(home: engine.home, def: d)
            out.append(Entry(id: "t:\(d.id)", name: d.name, icon: Icons.app(d.app), detail: snapDetail(g.listSnapshots(), g.newestSnapshot().flatMap { g.meta($0)?.ts }), suggestion: false))
        }
        if engine.hasZen && !Settings.load(engine.home).zenEnabled {
            out.append(Entry(id: "add:__zen__", name: "Zen Browser", icon: Icons.app("app.zen-browser.zen"),
                             detail: L.t("自動備份＋跨機還原（含工作區）", "auto-backup + cross-device restore"), suggestion: true))
        }
        let have = Set(defs.map { $0.id })
        for it in TargetStore.discover(engine.home) where !have.contains(it.id) {
            out.append(Entry(id: "add:\(it.id)", name: it.name, icon: Icons.app(it.app),
                             detail: it.note.isEmpty ? L.t("可備份的設定", "config") : it.note, suggestion: true))
        }
        return out
    }
    private func claudeDetail() -> String { snapDetail(claude.listSnapshots(), claude.newestSnapshot().flatMap { claude.meta($0)?.ts }) }
    private func zenDetail() -> String { snapDetail(engine.listZips(), engine.newestZip().flatMap { engine.zipMeta($0)?.ts }) }
    private func snapDetail(_ snaps: [String], _ ts: String?) -> String {
        guard let ts, !snaps.isEmpty else { return L.t("尚未備份", "no backup yet") }
        return L.t("最後備份 \(ts.replacingOccurrences(of: "-", with: " ")) · \(snaps.count) 份", "last \(ts.replacingOccurrences(of: "-", with: " ")) · \(snaps.count) snapshots")
    }

    private func makeMainRow(_ it: Entry, y: CGFloat, width: CGFloat, rowH: CGFloat) -> NSView {
        let row = RowView(entry: it, y: y, width: width, rowH: rowH)
        row.onRefresh = { [weak self] in self?.refreshMain() }
        if it.suggestion {
            row.onAdd = { [weak self] in self?.addEntry(it.id) }
        } else {
            row.onBackup = { [weak self] done in self?.performBackup(it.id, done) }
            row.onRestore = { [weak self] done in self?.performRestore(it.id, done) }
            row.onRemove = { [weak self] done in self?.performRemove(it.id, done) }
        }
        return row
    }

    // ---- settings page ----
    private func buildSettings(in host: NSView) {
        let pad = UI.s(28), rowH = UI.s(46)
        let w = host.bounds.width
        var y = host.bounds.height - UI.s(28)
        func row(_ title: String, _ subtitle: String, _ control: NSView) {
            y -= rowH
            let l = NSTextField(labelWithString: title)
            l.font = UI.font(13, .medium); l.frame = NSRect(x: pad, y: y + (subtitle.isEmpty ? (rowH - UI.s(18)) / 2 : rowH / 2 - UI.s(1)), width: w - pad * 2 - UI.s(220), height: UI.s(18))
            l.autoresizingMask = [.minYMargin]; host.addSubview(l)
            if !subtitle.isEmpty {
                let s = NSTextField(labelWithString: subtitle)
                s.font = UI.font(10.5); s.textColor = .secondaryLabelColor; s.lineBreakMode = .byTruncatingMiddle
                s.frame = NSRect(x: pad, y: y + rowH / 2 - UI.s(17), width: w - pad * 2 - UI.s(120), height: UI.s(14))
                s.autoresizingMask = [.minYMargin, .width]; host.addSubview(s)
            }
            control.setFrameOrigin(NSPoint(x: w - pad - control.frame.width, y: y + (rowH - control.frame.height) / 2))
            control.autoresizingMask = [.minXMargin, .minYMargin]; host.addSubview(control)
            let sep = NSBox(frame: NSRect(x: pad, y: y, width: w - pad * 2, height: 1))
            sep.boxType = .separator; sep.autoresizingMask = [.minYMargin, .width]; host.addSubview(sep)
        }
        // theme: follow system / light / dark
        let themeSeg = NSSegmentedControl(labels: [L.t("跟隨系統", "System"), L.t("淺色", "Light"), L.t("深色", "Dark")], trackingMode: .selectOne, target: self, action: #selector(settingsTheme(_:)))
        let th = Settings.load(engine.home).theme; themeSeg.selectedSegment = (th == "light") ? 1 : (th == "dark" ? 2 : 0)
        themeSeg.sizeToFit(); row(L.t("主題", "Theme"), "", themeSeg)
        // enlarge UI (manual, default off)
        let swz = NSSwitch(); swz.state = Settings.load(engine.home).uiZoom ? .on : .off
        swz.target = self; swz.action = #selector(settingsToggleZoom(_:)); swz.sizeToFit()
        row(L.t("放大介面", "Enlarge UI"), L.t("較大的字體與按鈕（1.1×）", "larger text & buttons (1.1×)"), swz)
        // pause zen (only when enabled)
        if zenOn {
            let sw = NSSwitch(); sw.state = paused ? .on : .off; sw.target = self; sw.action = #selector(settingsTogglePause(_:)); sw.sizeToFit()
            row(L.t("暫停 Zen 自動備份/還原", "Pause Zen auto backup/restore"), "", sw)
        }
        // launch at login
        let sw2 = NSSwitch(); sw2.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        sw2.target = self; sw2.action = #selector(settingsToggleLogin(_:)); sw2.sizeToFit()
        row(L.t("開機自動啟動", "Launch at login"), "", sw2)
        // language
        let seg = NSSegmentedControl(labels: [L.t("系統", "System"), "中文", "EN"], trackingMode: .selectOne, target: self, action: #selector(settingsLang(_:)))
        let cur = Settings.load(engine.home).language; seg.selectedSegment = (cur == "zh") ? 1 : (cur == "en" ? 2 : 0)
        seg.sizeToFit(); row(L.t("語言", "Language"), "", seg)
        // backup location
        let locBtn = PillButton(symbol: "externaldrive", title: L.t("變更…", "Change…")); locBtn.onClick = { [weak self] in self?.changeBackupLocation(); self?.refreshMain() }
        row(L.t("備份位置", "Backup location"), Engine.dropboxBase(home: engine.home), locBtn)   // Configgy root (holds zen/claude/targets)
        // about
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let gh = PillButton(symbol: "arrow.up.forward.square", title: "GitHub"); gh.onClick = { [weak self] in self?.about() }
        row(L.t("關於 Configgy", "About Configgy"), "v\(ver)", gh)
    }
    @objc func settingsToggleZoom(_ s: NSSwitch) {
        var st = Settings.load(engine.home); st.uiZoom = (s.state == .on); Settings.save(st, home: engine.home)
        // rebuild on the next runloop (let this click finish) with no close animation, no premature release
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UI.scale = UI.compute()
            self.mainWin?.orderOut(nil)
            self.mainWin = nil; self.toolbarHost = nil; self.contentHost = nil; self.tabsView = nil
            self.showMain()                      // stays on the Settings page (mainSettings remains true)
        }
    }
    func applyTheme() {
        switch Settings.load(engine.home).theme {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil          // follow system
        }
    }
    @objc func settingsTheme(_ s: NSSegmentedControl) {
        let v = ["system", "light", "dark"][s.selectedSegment]
        var st = Settings.load(engine.home); st.theme = (v == "system") ? nil : v; Settings.save(st, home: engine.home)
        applyTheme(); refreshMain()
    }
    @objc func settingsTogglePause(_ s: NSSwitch) { paused = (s.state == .on); buildMenu() }
    @objc func settingsToggleLogin(_ s: NSSwitch) {
        do { if s.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { info(L.t("無法變更開機自動啟動：\(error.localizedDescription)", "Couldn't change Launch at Login: \(error.localizedDescription)")); s.state = (SMAppService.mainApp.status == .enabled) ? .on : .off }
    }
    @objc func settingsLang(_ s: NSSegmentedControl) {
        let code = ["system", "zh", "en"][s.selectedSegment]
        var st = Settings.load(engine.home); st.language = (code == "system") ? nil : code; Settings.save(st, home: engine.home)
        L.lang = L.resolve(st.language); buildMenu(); refreshMain()
    }
    @objc func addFolderFromMain() { addTarget(); refreshMain() }

    // ---- confirm removal (0 cancel / 1 config only / 2 + delete files) ----
    private func confirmRemoval(configLabel: String, deleteLabel: String, body: String) -> Int {
        let d = "display dialog \"\(body)\" buttons {\"\(L.t("取消", "Cancel"))\", \"\(configLabel)\", \"\(deleteLabel)\"} default button \"\(configLabel)\" with title \"Configgy\""
        let (code, out) = engine.sh("/usr/bin/osascript", ["-e", d])
        if code != 0 { return 0 }
        let s = String(data: out, encoding: .utf8) ?? ""
        if s.contains(deleteLabel) { return 2 }
        if s.contains(configLabel) { return 1 }
        return 0
    }
    // confirm + perform removal on a bg queue; completion(removed) on main so the row can crumble
    func performRemove(_ id: String, _ done: @escaping (Bool) -> Void) {
        q.async {
            let removed = self.doRemove(id)
            DispatchQueue.main.async { done(removed) }
        }
    }
    private func doRemove(_ id: String) -> Bool {
        if id == "zen" {
            let n = engine.listZips().count
            let c = confirmRemoval(configLabel: L.t("只停用", "Disable"), deleteLabel: L.t("停用並刪備份", "Disable & delete"),
                body: L.t("停用 Zen 備份？\\n\\n• 只停用：不再自動備份，保留雲端 \(n) 份\\n• 停用並刪備份：同時刪掉雲端 Zen 備份（不可復原）",
                          "Disable Zen backup?\\n\\n• Disable: stop auto-backup, keep the \(n) backups\\n• Disable & delete: also remove the cloud Zen backups (irreversible)"))
            if c == 0 { return false }
            var st = Settings.load(engine.home); st.zenEnabled = false; Settings.save(st, home: engine.home)
            DispatchQueue.main.async { self.zenOn = false }
            if c == 2, engine.isTest || canAccessBackup() { try? FileManager.default.removeItem(atPath: engine.dropboxDir) }
            return true
        }
        guard id.hasPrefix("t:"), let d = TargetStore.load(engine.home).first(where: { $0.id == String(id.dropFirst(2)) }) else { return false }
        let g = GenericBackup(home: engine.home, def: d)
        let n = g.listSnapshots().count
        let c = confirmRemoval(configLabel: L.t("只移除設定", "Config only"), deleteLabel: L.t("連備份一起刪", "Delete backups too"),
            body: L.t("移除「\(d.name)」？\\n\\n• 只移除設定：從清單拿掉，保留雲端 \(n) 份備份\\n• 連備份一起刪：同時刪掉雲端備份（不可復原）",
                      "Remove \"\(d.name)\"?\\n\\n• Config only: drop from the list, keep the \(n) cloud backups\\n• Delete backups too: also remove the cloud backups (irreversible)"))
        if c == 0 { return false }
        TargetStore.remove(d.id, home: engine.home)
        if c == 2, engine.isTest || canAccessBackup() { try? FileManager.default.removeItem(atPath: g.dir) }
        return true
    }

    // perform backup on a bg queue; completion(success) on main (no refresh — the row drives the post-animation refresh)
    func performBackup(_ id: String, _ done: @escaping (Bool) -> Void) {
        fdaOK = engine.isTest ? true : canAccessBackup()
        guard requireFDA() else { done(false); return }
        let op: (() -> BackupResult)?
        if id == "claude" { op = { self.claude.backup() } }
        else if id == "zen" { op = { self.engine.manualBackup() } }
        else if id.hasPrefix("t:"), let d = TargetStore.load(engine.home).first(where: { $0.id == String(id.dropFirst(2)) }) { op = { GenericBackup(home: self.engine.home, def: d).backup() } }
        else { op = nil }
        guard let op else { done(false); return }
        q.async { let r = op(); DispatchQueue.main.async { if case .done = r { done(true) } else { done(false) } } }
    }
    func performRestore(_ id: String, _ done: @escaping (Bool) -> Void) {
        fdaOK = engine.isTest ? true : canAccessBackup()
        guard requireFDA() else { done(false); return }
        q.async {
            let o: OpOutcome
            if id == "claude" { o = self.claudeRestoreFlow() }
            else if id == "zen" { o = self.interactiveRestore(autoDismiss: false) }
            else if id.hasPrefix("t:"), let d = TargetStore.load(self.engine.home).first(where: { $0.id == String(id.dropFirst(2)) }) { o = self.genericRestoreFlow(d) }
            else { o = .neutral }
            DispatchQueue.main.async { if case .success = o { done(true) } else { done(false) } }
        }
    }
    private func addEntry(_ id: String) {
        let key = String(id.dropFirst(4))
        if key == "__zen__" { var s = Settings.load(engine.home); s.zenEnabled = true; Settings.save(s, home: engine.home); zenOn = engine.hasZen }
        else if let it = TargetStore.discover(engine.home).first(where: { $0.id == key }) {
            TargetStore.add(TargetDef(id: it.id, name: it.name, paths: it.paths, excludes: it.excludes, app: it.app), home: engine.home)
        }
        buildMenu(); refreshMain()
    }
}
