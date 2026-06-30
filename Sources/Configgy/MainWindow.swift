import AppKit

// One unified window (Mole-style): every backup target in a single list with
// inline Back Up / Restore actions, plus a "suggested" section to add more.
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
        let w: CGFloat = 760, h: CGFloat = 560
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = "Configgy"; win.titlebarAppearsTransparent = true; win.minSize = NSSize(width: 620, height: 420)
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .underWindowBackground; bg.blendingMode = .behindWindow; bg.state = .active
        bg.autoresizingMask = [.width, .height]; win.contentView = bg

        let title = NSTextField(labelWithString: "Configgy")
        title.font = .systemFont(ofSize: 18, weight: .bold); title.frame = NSRect(x: 24, y: h - 50, width: 300, height: 24)
        title.autoresizingMask = [.minYMargin]; bg.addSubview(title)
        let sub = NSTextField(labelWithString: "")
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 24, y: h - 70, width: 400, height: 16); sub.autoresizingMask = [.minYMargin]
        sub.identifier = NSUserInterfaceItemIdentifier("subtitle"); bg.addSubview(sub)

        func tool(_ t: String, _ sel: Selector, x: CGFloat, wdt: CGFloat) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel); b.bezelStyle = .rounded; b.controlSize = .small
            b.font = .systemFont(ofSize: 11); b.frame = NSRect(x: x, y: h - 50, width: wdt, height: 24)
            b.autoresizingMask = [.minXMargin, .minYMargin]; bg.addSubview(b); return b
        }
        _ = tool(L.t("掃描建議的設定", "Scan for Configs"), #selector(scanFromMain), x: w - 290, wdt: 130)
        _ = tool(L.t("新增資料夾", "Add Folder"), #selector(addFolderFromMain), x: w - 152, wdt: 96)
        _ = tool("↻", #selector(refreshMainBtn), x: w - 48, wdt: 34)

        let scroll = NSScrollView(frame: NSRect(x: 14, y: 14, width: w - 28, height: h - 92))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autoresizingMask = [.width, .height]
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w - 28, height: 0)); doc.autoresizingMask = [.width]
        scroll.documentView = doc; bg.addSubview(scroll)
        win.delegate = self
        mainWin = win; mainDoc = doc; mainStatus = sub
    }

    private func entries() -> [Entry] {
        var out: [Entry] = []
        out.append(Entry(id: "claude", name: "Claude Code", icon: Icons.app("com.anthropic.claude"),
                         detail: claudeDetail(), suggestion: false))
        if zenOn {
            out.append(Entry(id: "zen", name: "Zen Browser", icon: Icons.app("app.zen-browser.zen"),
                             detail: zenDetail(), suggestion: false))
        }
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
        (mainStatus)?.stringValue = L.t("備份目標 \(active.count) 個", "\(active.count) backup target(s)")
        doc.subviews.forEach { $0.removeFromSuperview() }
        let rowH: CGFloat = 64; let w = doc.bounds.width
        var y: CGFloat = 6
        var sawSuggestionHeader = false
        for it in items {
            if it.suggestion && !sawSuggestionHeader {
                let hdr = NSTextField(labelWithString: L.t("建議加入", "Suggestions"))
                hdr.font = .systemFont(ofSize: 11, weight: .semibold); hdr.textColor = .secondaryLabelColor
                hdr.frame = NSRect(x: 18, y: y + 6, width: w - 36, height: 16); doc.addSubview(hdr)
                y += 28; sawSuggestionHeader = true
            }
            doc.addSubview(makeMainRow(it, y: y, width: w, rowH: rowH))
            y += rowH + 4
        }
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 6, 1))
    }

    private func makeMainRow(_ it: Entry, y: CGFloat, width: CGFloat, rowH: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 10, y: y, width: width - 20, height: rowH))
        row.wantsLayer = true; row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.10).cgColor
        row.autoresizingMask = [.width]
        let iv = NSImageView(frame: NSRect(x: 14, y: (rowH - 38) / 2, width: 38, height: 38))
        iv.image = it.icon; iv.imageScaling = .scaleProportionallyUpOrDown; row.addSubview(iv)
        let name = NSTextField(labelWithString: it.name)
        name.font = .systemFont(ofSize: 13.5, weight: .semibold)
        name.frame = NSRect(x: 64, y: rowH / 2 + 1, width: width - 20 - 64 - 220, height: 18)
        name.autoresizingMask = [.width]; row.addSubview(name)
        let detail = NSTextField(labelWithString: it.detail)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: 64, y: rowH / 2 - 18, width: width - 20 - 64 - 220, height: 15)
        detail.autoresizingMask = [.width]; row.addSubview(detail)

        func btn(_ t: String, _ sel: Selector, x: CGFloat, wdt: CGFloat) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel); b.bezelStyle = .rounded; b.controlSize = .regular
            b.frame = NSRect(x: x, y: (rowH - 30) / 2, width: wdt, height: 30); b.autoresizingMask = [.minXMargin]
            b.identifier = NSUserInterfaceItemIdentifier(it.id); row.addSubview(b); return b
        }
        if it.suggestion {
            let add = btn(L.t("加入", "Add"), #selector(mainAdd(_:)), x: width - 20 - 92, wdt: 80)
            add.keyEquivalent = ""
        } else {
            _ = btn(L.t("還原", "Restore"), #selector(mainRestore(_:)), x: width - 20 - 196, wdt: 92)
            let b = btn(L.t("備份", "Back Up"), #selector(mainBackup(_:)), x: width - 20 - 98, wdt: 88)
            b.bezelStyle = .rounded
        }
        return row
    }

    @objc func mainBackup(_ s: NSButton) { backupEntry((s.identifier?.rawValue) ?? "") }
    @objc func mainRestore(_ s: NSButton) { restoreEntry((s.identifier?.rawValue) ?? "") }
    @objc func mainAdd(_ s: NSButton) { addEntry((s.identifier?.rawValue) ?? "") }
    @objc func refreshMainBtn() { refreshMain() }
    @objc func scanFromMain() { discoverTargets(); refreshMain() }
    @objc func addFolderFromMain() { addTarget(); refreshMain() }

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
