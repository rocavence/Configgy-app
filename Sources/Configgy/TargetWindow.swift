import AppKit

// A rich per-target window (Mole-style): app-icon header, snapshot history list,
// and Back Up / Restore actions in one place. Opened for both backup and restore.
// Runs modal; backup/restore run on a background queue and update the UI live.
final class TargetWindow: NSObject {
    private var win: NSWindow!
    private let q = DispatchQueue(label: "com.rocavence.configgy.targetwin")
    private var doc: FlippedView!
    private var status: NSTextField!
    private var rowViews: [String: NSView] = [:]
    private var selectedId: String?
    private let width: CGFloat = 560, rowH: CGFloat = 46
    private var rowIcon: NSImage = NSImage()

    private var snapshots: () -> [PickerRow] = { [] }
    private var access: () -> Bool = { true }
    private var doBackup: () -> BackupResult = { .failed }
    private var doPreview: (String) -> ChangeSet = { _ in ChangeSet() }
    private var doConfirm: (ChangeSet) -> Bool = { _ in false }
    private var doRestore: (String) -> RestoreResult = { _ in .failed }

    static func present(title: String, icon: NSImage, subtitle: String,
                        access: @escaping () -> Bool, snapshots: @escaping () -> [PickerRow],
                        backup: @escaping () -> BackupResult, preview: @escaping (String) -> ChangeSet,
                        confirm: @escaping (ChangeSet) -> Bool, restore: @escaping (String) -> RestoreResult) {
        let w = TargetWindow()
        w.snapshots = snapshots; w.access = access; w.doBackup = backup
        w.doPreview = preview; w.doConfirm = confirm; w.doRestore = restore; w.rowIcon = icon
        w.run(title: title, icon: icon, subtitle: subtitle)
    }

    private func run(title: String, icon: NSImage, subtitle: String) {
        let listH: CGFloat = 286, headerH: CGFloat = 84, footerH: CGFloat = 62
        let winH = headerH + listH + footerH
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: winH),
                       styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Configgy"; win.titlebarAppearsTransparent = true; win.isMovableByWindowBackground = true
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: winH))
        bg.material = .windowBackground; bg.blendingMode = .behindWindow; bg.state = .active
        bg.autoresizingMask = [.width, .height]; win.contentView = bg

        let iv = NSImageView(frame: NSRect(x: 22, y: winH - 64, width: 44, height: 44))
        iv.image = icon; iv.imageScaling = .scaleProportionallyUpOrDown; bg.addSubview(iv)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 15, weight: .semibold); t.frame = NSRect(x: 78, y: winH - 42, width: width - 98, height: 22)
        bg.addSubview(t)
        let s = NSTextField(labelWithString: subtitle)
        s.font = .systemFont(ofSize: 11); s.textColor = .secondaryLabelColor; s.lineBreakMode = .byTruncatingMiddle
        s.frame = NSRect(x: 78, y: winH - 62, width: width - 98, height: 16); bg.addSubview(s)

        let sec = NSTextField(labelWithString: L.t("歷史快照（選一份還原）", "Snapshots (pick one to restore)"))
        sec.font = .systemFont(ofSize: 11, weight: .medium); sec.textColor = .secondaryLabelColor
        sec.frame = NSRect(x: 20, y: footerH + listH - 2, width: width - 40, height: 16); bg.addSubview(sec)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: footerH, width: width - 32, height: listH - 22))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autoresizingMask = [.width, .height]
        doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width - 32, height: 0))
        scroll.documentView = doc; bg.addSubview(scroll)
        reload()

        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 20, y: 20, width: 190, height: 18); bg.addSubview(status)

        let backupB = NSButton(title: L.t("立即備份", "Back Up Now"), target: self, action: #selector(backupTapped))
        backupB.bezelStyle = .rounded; backupB.frame = NSRect(x: width - 350, y: 14, width: 120, height: 32)
        let restoreB = NSButton(title: L.t("還原所選", "Restore Selected"), target: self, action: #selector(restoreTapped))
        restoreB.bezelStyle = .rounded; restoreB.frame = NSRect(x: width - 224, y: 14, width: 132, height: 32)
        let doneB = NSButton(title: L.t("完成", "Done"), target: self, action: #selector(doneTapped))
        doneB.bezelStyle = .rounded; doneB.keyEquivalent = "\r"; doneB.frame = NSRect(x: width - 84, y: 14, width: 70, height: 32)
        [backupB, restoreB, doneB].forEach { $0.autoresizingMask = [.minXMargin]; bg.addSubview($0) }

        win.center(); NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: win); win.orderOut(nil)
    }

    private func reload() {
        let snaps = snapshots()
        doc.subviews.forEach { $0.removeFromSuperview() }; rowViews.removeAll()
        doc.frame = NSRect(x: 0, y: 0, width: width - 32, height: max(CGFloat(snaps.count) * rowH, 1))
        guard !snaps.isEmpty else {
            let empty = NSTextField(labelWithString: L.t("（尚無快照，按「立即備份」建立第一份）", "(no snapshots yet — Back Up Now)"))
            empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor
            empty.frame = NSRect(x: 12, y: 10, width: width - 60, height: 18); doc.addSubview(empty)
            selectedId = nil; return
        }
        selectedId = snaps.first?.id
        for (i, it) in snaps.enumerated() { doc.addSubview(makeRow(it, y: CGFloat(i) * rowH)) }
    }

    private func makeRow(_ it: PickerRow, y: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 6, y: y + 3, width: width - 32 - 12, height: rowH - 6))
        row.wantsLayer = true; row.layer?.cornerRadius = 8
        row.identifier = NSUserInterfaceItemIdentifier(it.id); rowViews[it.id] = row
        if it.id == selectedId { row.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor }
        let iv = NSImageView(frame: NSRect(x: 12, y: (rowH - 6 - 26) / 2, width: 26, height: 26))
        iv.image = it.icon; iv.imageScaling = .scaleProportionallyUpOrDown; row.addSubview(iv)
        let title = NSTextField(labelWithString: it.title)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.frame = NSRect(x: 50, y: (rowH - 6 - 18) / 2, width: width - 32 - 12 - 60, height: 18); row.addSubview(title)
        row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowTapped(_:))))
        return row
    }
    @objc private func rowTapped(_ g: NSClickGestureRecognizer) {
        guard let id = g.view?.identifier?.rawValue else { return }
        if let prev = selectedId, let pv = rowViews[prev] { pv.layer?.backgroundColor = nil }
        selectedId = id
        rowViews[id]?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
    }

    private func note(_ s: String) { status.stringValue = s }
    @objc private func backupTapped() {
        guard access() else { note(L.t("需先授予完整磁碟取用權", "Grant Full Disk Access first")); return }
        note(L.t("備份中…", "Backing up…"))
        q.async {
            let r = self.doBackup()
            DispatchQueue.main.async {
                switch r {
                case .done: self.note(L.t("✓ 已備份", "✓ Backed up"))
                case .skipped: self.note(L.t("設定沒變，略過", "No change, skipped"))
                case .failed: self.note(L.t("✗ 備份失敗", "✗ Backup failed"))
                }
                self.reload()
            }
        }
    }
    @objc private func restoreTapped() {
        guard let zip = selectedId else { note(L.t("請先選一份快照", "Select a snapshot first")); return }
        guard access() else { note(L.t("需先授予完整磁碟取用權", "Grant Full Disk Access first")); return }
        q.async {
            let ok = self.doConfirm(self.doPreview(zip))   // diff preview + confirm
            guard ok else { return }
            DispatchQueue.main.async {
                self.note(L.t("還原中…", "Restoring…"))
                self.q.async {
                    let r = self.doRestore(zip)
                    DispatchQueue.main.async {
                        self.note(r.isDone ? L.t("✓ 已還原", "✓ Restored") : L.t("✗ 還原失敗", "✗ Restore failed"))
                        self.reload()
                    }
                }
            }
        }
    }
    @objc private func doneTapped() { NSApp.stopModal(withCode: .OK) }
}

private extension RestoreResult {
    var isDone: Bool { if case .done = self { return true }; return false }
}
