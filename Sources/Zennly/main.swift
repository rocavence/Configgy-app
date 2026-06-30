import AppKit

// ===================== CLI mode =====================
// `Zennly backup|list|status|restore [zip]` runs headless and exits.
let args = CommandLine.arguments
if args.count > 1 {
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
            else { print("Usage: Zennly workspaces <zip>") }
        case "restore":
            if args.count >= 5, args[3] == "ws" {
                e.restoreWorkspaces(args[2], uuids: Set(args[4...]))
            } else if args.count > 2 {
                e.restore(args[2])
            } else { e.promptRestore() }
        default:
            print("Usage: Zennly [backup|list|status|restore [zip]]")
        }
    } catch {
        FileHandle.standardError.write(Data("[zennly] \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}

// ===================== GUI menubar mode =====================
enum IconState { case idle, working, success, failure }
enum OpOutcome { case success, failure, neutral }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var engine: Engine!
    let q = DispatchQueue(label: "com.rocavence.zennly.engine")
    var timer: Timer?
    var wasRunning = false
    var busy = false
    var paused = false
    var idleRevert: DispatchWorkItem?
    let header = NSMenuItem(title: "Zennly", action: nil, keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "暫停自動備份/還原", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        do { engine = try Engine() }
        catch {
            let a = NSAlert(); a.messageText = "Zennly 無法啟動"; a.informativeText = error.localizedDescription
            a.runModal(); NSApp.terminate(nil); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.wantsLayer = true
        setIcon(.idle)
        pauseItem.target = self
        buildMenu()
        wasRunning = engine.zenRunning()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func buildMenu() {
        let m = NSMenu(); m.delegate = self
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        m.addItem(withTitle: "立即備份", action: #selector(doBackup), keyEquivalent: "b").target = self
        m.addItem(withTitle: "還原備份…", action: #selector(doRestore), keyEquivalent: "r").target = self
        m.addItem(.separator())
        m.addItem(pauseItem)
        m.addItem(withTitle: "開啟 Dropbox 備份資料夾", action: #selector(openDropbox), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "結束 Zennly", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = m
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshHeader() }
    func refreshHeader() {
        let st = engine.readState()
        let cur = st.currentZip.map { engine.label($0) } ?? "尚未備份"
        header.title = (engine.zenRunning() ? "● Zen 開啟中" : "○ Zen 已關閉") + (busy ? "（處理中…）" : "")
        let sub = NSMenuItem(title: "目前：\(cur)", action: nil, keyEquivalent: ""); sub.isEnabled = false
        // refresh the secondary info line (index 1 is the separator after header; keep header only)
        header.toolTip = "目前對應備份：\(cur)\nDropbox：\(engine.dropboxDir)"
        pauseItem.state = paused ? .on : .off
    }

    // ---- menubar icon state + animation ----
    func symbolImage(_ name: String, color: NSColor? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Zennly") else { return nil }
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

    // ---- watch loop ----
    func tick() {
        if paused || busy { return }
        let now = engine.zenRunning()
        if now && !wasRunning {                                   // OPEN edge
            let newest = engine.newestZip(); let st = engine.readState()
            if let nz = newest, nz != st.currentZip, nz != st.dismissedZip {
                runOp { Thread.sleep(forTimeInterval: 2); return self.outcome(self.engine.promptRestore(autoDismiss: true)) }
            }
        } else if !now && wasRunning {                            // QUIT edge
            if !FileManager.default.fileExists(atPath: engine.stateDir + "/restoring.lock") {
                runOp { self.outcome(self.engine.backup()) }
            }
        }
        wasRunning = now
    }

    // ---- actions ----
    @objc func doBackup() { runOp { self.outcome(self.engine.manualBackup()) } }
    @objc func doRestore() { runOp { self.outcome(self.engine.promptRestore()) } }
    @objc func openDropbox() {
        try? FileManager.default.createDirectory(atPath: engine.dropboxDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: engine.dropboxDir))
    }
    @objc func togglePause() { paused.toggle(); refreshHeader() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
