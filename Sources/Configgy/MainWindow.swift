import AppKit

// One unified window (Mole-style): every backup target in a single list with
// inline Back Up / Restore actions, plus a "suggested" section to add more.
// Scales 1.5× on 3K+ displays (see UI).
extension AppDelegate {
    struct Entry { let id: String; let name: String; let icon: NSImage; let detail: String; let suggestion: Bool }

    @objc func showMain() {
        if mainWin == nil { buildMainWindow() }
        refreshMain()
        NSApp.setActivationPolicy(.regular)        // give the window real focus + a dock icon while open
        mainWin?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == mainWin { NSApp.setActivationPolicy(.accessory) }
    }

    private func buildMainWindow() {
        let w = UI.s(760), h = UI.s(560)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Configgy"; win.titlebarAppearsTransparent = true
        win.minSize = NSSize(width: UI.s(620), height: UI.s(420))
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .underWindowBackground; bg.blendingMode = .behindWindow; bg.state = .active
        bg.autoresizingMask = [.width, .height]; win.contentView = bg

        let title = NSTextField(labelWithString: "Configgy")
        title.font = UI.font(17, .bold); title.frame = NSRect(x: UI.s(20), y: h - UI.s(40), width: UI.s(260), height: UI.s(22))
        title.autoresizingMask = [.minYMargin]; bg.addSubview(title)
        let sub = NSTextField(labelWithString: "")
        sub.font = UI.font(11.5); sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: UI.s(20), y: h - UI.s(58), width: UI.s(400), height: UI.s(15)); sub.autoresizingMask = [.minYMargin]
        sub.identifier = NSUserInterfaceItemIdentifier("subtitle"); bg.addSubview(sub)

        // toolbar icon+text buttons, tight group, right-aligned, vertically centered with the title
        var tx = w - UI.s(20)
        func tool(_ sym: String, _ titleText: String, _ act: @escaping () -> Void) {
            let b = PillButton(symbol: sym, title: titleText); b.onClick = act
            tx -= b.frame.width
            b.setFrameOrigin(NSPoint(x: tx, y: h - UI.s(46)))
            b.autoresizingMask = [.minXMargin, .minYMargin]; bg.addSubview(b)
            tx -= UI.s(8)
        }
        tool("folder", L.t("備份資料夾", "Backup Folder")) { [weak self] in self?.openDropbox() }
        tool("arrow.clockwise", L.t("重新掃描", "Rescan")) { [weak self] in self?.refreshMain() }
        tool("folder.badge.plus", L.t("加入自訂備份", "Add Custom")) { [weak self] in self?.addFolderFromMain() }

        let scroll = NSScrollView(frame: NSRect(x: UI.s(16), y: UI.s(16), width: w - UI.s(32), height: h - UI.s(84)))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autoresizingMask = [.width, .height]
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w - UI.s(32), height: 0)); doc.autoresizingMask = [.width]
        scroll.documentView = doc; bg.addSubview(scroll)
        win.delegate = self
        mainWin = win; mainDoc = doc; mainStatus = sub
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
                             detail: L.t("建議加入 · 自動備份＋跨機還原", "suggested · auto-backup + restore"), suggestion: true))
        }
        let have = Set(defs.map { $0.id })
        for it in TargetStore.discover(engine.home) where !have.contains(it.id) {
            out.append(Entry(id: "add:\(it.id)", name: it.name, icon: Icons.app(it.app),
                             detail: it.note.isEmpty ? L.t("建議加入", "suggested") : L.t("建議加入 · \(it.note)", "suggested · \(it.note)"), suggestion: true))
        }
        return out
    }
    private func claudeDetail() -> String { snapDetail(claude.listSnapshots(), claude.newestSnapshot().flatMap { claude.meta($0)?.ts }) }
    private func zenDetail() -> String { snapDetail(engine.listZips(), engine.newestZip().flatMap { engine.zipMeta($0)?.ts }) }
    private func snapDetail(_ snaps: [String], _ newestTs: String?) -> String {
        guard let ts = newestTs, !snaps.isEmpty else { return L.t("尚未備份", "no backup yet") }
        return L.t("最後備份 \(ts.replacingOccurrences(of: "-", with: " ")) · \(snaps.count) 份", "last \(ts.replacingOccurrences(of: "-", with: " ")) · \(snaps.count) snapshots")
    }

    func refreshMain() {
        guard let doc = mainDoc else { return }
        let items = entries()
        let active = items.filter { !$0.suggestion }
        mainStatus?.stringValue = L.t("備份目標 \(active.count) 個", "\(active.count) backup target(s)")
        doc.subviews.forEach { $0.removeFromSuperview() }
        let rowH = UI.s(60); let w = doc.bounds.width
        var y = UI.s(4); var sawSuggestionHeader = false
        for it in items {
            if it.suggestion && !sawSuggestionHeader {
                let hdr = NSTextField(labelWithString: L.t("建議加入", "SUGGESTIONS").uppercased())
                hdr.font = UI.font(10.5, .semibold); hdr.textColor = .tertiaryLabelColor
                hdr.frame = NSRect(x: UI.s(18), y: y + UI.s(8), width: w - UI.s(36), height: UI.s(14)); doc.addSubview(hdr)
                y += UI.s(28); sawSuggestionHeader = true
            }
            doc.addSubview(makeMainRow(it, y: y, width: w, rowH: rowH))
            y += rowH + UI.s(6)
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(y + UI.s(6), 1))
    }

    private func makeMainRow(_ it: Entry, y: CGFloat, width: CGFloat, rowH: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: UI.s(12), y: y, width: width - UI.s(24), height: rowH))
        row.wantsLayer = true; row.layer?.cornerRadius = UI.s(13)
        row.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.12).cgColor
        row.autoresizingMask = [.width]
        let inner = width - UI.s(24)
        let iconX = UI.s(16), isz = UI.s(44)
        let iv = NSImageView(frame: NSRect(x: iconX, y: (rowH - isz) / 2, width: isz, height: isz))
        iv.image = it.icon; iv.imageScaling = .scaleProportionallyUpOrDown; row.addSubview(iv)

        // action buttons — a tight right-aligned cluster (rightmost added first)
        var x = inner - UI.s(14)
        let id = it.id
        func place(_ sym: String, _ t: String, _ destructive: Bool, _ act: @escaping () -> Void) {
            let b = PillButton(symbol: sym, title: t, destructive: destructive); b.onClick = act
            x -= b.frame.width
            b.setFrameOrigin(NSPoint(x: x, y: (rowH - b.frame.height) / 2))
            b.autoresizingMask = [.minXMargin]; row.addSubview(b)
            x -= UI.s(6)
        }
        if it.suggestion {
            place("plus.circle.fill", L.t("加入", "Add"), false) { [weak self] in self?.addEntry(id) }
        } else {
            place("icloud.and.arrow.up", L.t("備份", "Back Up"), false) { [weak self] in self?.backupEntry(id) }
            place("clock.arrow.circlepath", L.t("還原", "Restore"), false) { [weak self] in self?.restoreEntry(id) }
            if id.hasPrefix("t:") { place("trash", L.t("移除", "Remove"), true) { [weak self] in self?.removeEntry(id) } }
            else if id == "zen" { place("pause.circle", L.t("停用", "Disable"), false) { [weak self] in self?.removeEntry(id) } }
        }

        let nameX = iconX + isz + UI.s(12)
        let textW = max(x - UI.s(8) - nameX, UI.s(80))
        let name = NSTextField(labelWithString: it.name)
        name.font = UI.font(13, .semibold); name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: nameX, y: rowH / 2 + UI.s(2), width: textW, height: UI.s(17))
        name.autoresizingMask = [.width]; row.addSubview(name)
        let detail = NSTextField(labelWithString: it.detail)
        detail.font = UI.font(11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: nameX, y: rowH / 2 - UI.s(17), width: textW, height: UI.s(14))
        detail.autoresizingMask = [.width]; row.addSubview(detail)
        return row
    }

    @objc func addFolderFromMain() { addTarget(); refreshMain() }

    // 0 = cancel, 1 = config/setting only, 2 = also delete backup files
    private func confirmRemoval(title: String, configLabel: String, deleteLabel: String, body: String) -> Int {
        let d = "display dialog \"\(body)\" buttons {\"\(L.t("取消", "Cancel"))\", \"\(configLabel)\", \"\(deleteLabel)\"} default button \"\(configLabel)\" with title \"\(title)\""
        let (code, out) = engine.sh("/usr/bin/osascript", ["-e", d])
        if code != 0 { return 0 }
        let s = String(data: out, encoding: .utf8) ?? ""
        if s.contains(deleteLabel) { return 2 }
        if s.contains(configLabel) { return 1 }
        return 0
    }
    private func removeEntry(_ id: String) {
        if id == "zen" {
            let n = engine.listZips().count
            let choice = confirmRemoval(
                title: "Configgy", configLabel: L.t("只停用", "Disable"), deleteLabel: L.t("停用並刪備份", "Disable & delete"),
                body: L.t("停用 Zen 備份？\\n\\n• 只停用：不再自動備份，保留雲端 \(n) 份\\n• 停用並刪備份：同時刪掉雲端 Zen 備份（不可復原）",
                          "Disable Zen backup?\\n\\n• Disable: stop auto-backup, keep the \(n) backups\\n• Disable & delete: also remove the cloud Zen backups (irreversible)"))
            if choice == 0 { return }
            var st = Settings.load(engine.home); st.zenEnabled = false; Settings.save(st, home: engine.home); zenOn = false
            if choice == 2 { fdaOK = engine.isTest ? true : canAccessBackup(); if requireFDA() { try? FileManager.default.removeItem(atPath: engine.dropboxDir) } }
            buildMenu(); refreshMain(); return
        }
        guard id.hasPrefix("t:"), let d = TargetStore.load(engine.home).first(where: { $0.id == String(id.dropFirst(2)) }) else { return }
        let g = GenericBackup(home: engine.home, def: d)
        let n = g.listSnapshots().count
        let choice = confirmRemoval(
            title: "Configgy", configLabel: L.t("只移除設定", "Config only"), deleteLabel: L.t("連備份一起刪", "Delete backups too"),
            body: L.t("移除「\(d.name)」？\\n\\n• 只移除設定：從清單拿掉，保留雲端 \(n) 份備份\\n• 連備份一起刪：同時刪掉雲端備份（不可復原）",
                      "Remove \"\(d.name)\"?\\n\\n• Config only: drop from the list, keep the \(n) cloud backups\\n• Delete backups too: also remove the cloud backups (irreversible)"))
        if choice == 0 { return }
        TargetStore.remove(d.id, home: engine.home)
        if choice == 2 { fdaOK = engine.isTest ? true : canAccessBackup(); if requireFDA() { try? FileManager.default.removeItem(atPath: g.dir) } }
        buildMenu(); refreshMain()
    }

    private func backupEntry(_ id: String) {
        fdaOK = engine.isTest ? true : canAccessBackup()
        guard requireFDA() else { return }
        let op: (() -> BackupResult)?
        if id == "claude" { op = { self.claude.backup() } }
        else if id == "zen" { op = { self.engine.manualBackup() } }
        else if id.hasPrefix("t:"), let d = TargetStore.load(engine.home).first(where: { $0.id == String(id.dropFirst(2)) }) {
            op = { GenericBackup(home: self.engine.home, def: d).backup() }
        } else { op = nil }
        guard let op else { return }
        runOp { let r = op(); DispatchQueue.main.async { self.refreshMain() }; return self.outcome(r) }
    }
    private func restoreEntry(_ id: String) {
        fdaOK = engine.isTest ? true : canAccessBackup()
        guard requireFDA() else { return }
        runOp {
            let o: OpOutcome
            if id == "claude" { o = self.claudeRestoreFlow() }
            else if id == "zen" { o = self.interactiveRestore(autoDismiss: false) }
            else if id.hasPrefix("t:"), let d = TargetStore.load(self.engine.home).first(where: { $0.id == String(id.dropFirst(2)) }) { o = self.genericRestoreFlow(d) }
            else { o = .neutral }
            DispatchQueue.main.async { self.refreshMain() }
            return o
        }
    }
    private func addEntry(_ id: String) {
        let key = String(id.dropFirst(4))      // strip "add:"
        if key == "__zen__" {
            var s = Settings.load(engine.home); s.zenEnabled = true; Settings.save(s, home: engine.home); zenOn = engine.hasZen
        } else if let it = TargetStore.discover(engine.home).first(where: { $0.id == key }) {
            TargetStore.add(TargetDef(id: it.id, name: it.name, paths: it.paths, excludes: it.excludes, app: it.app), home: engine.home)
        }
        buildMenu(); refreshMain()
    }
}
