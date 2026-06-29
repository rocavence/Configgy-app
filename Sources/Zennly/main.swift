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
        case "restore":
            if args.count > 2 { e.restore(args[2]) } else { e.promptRestore() }
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var engine: Engine!
    let q = DispatchQueue(label: "com.rocavence.zennly.engine")
    var timer: Timer?
    var wasRunning = false
    var busy = false
    var paused = false
    let header = NSMenuItem(title: "Zennly", action: nil, keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "暫停自動備份/還原", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        do { engine = try Engine() }
        catch {
            let a = NSAlert(); a.messageText = "Zennly 無法啟動"; a.informativeText = error.localizedDescription
            a.runModal(); NSApp.terminate(nil); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "externaldrive.badge.timemachine", accessibilityDescription: "Zennly")
            b.image?.isTemplate = true
        }
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

    // ---- watch loop ----
    func tick() {
        if paused || busy { return }
        let now = engine.zenRunning()
        if now && !wasRunning {                                   // OPEN edge
            let newest = engine.newestZip(); let st = engine.readState()
            if let nz = newest, nz != st.currentZip, nz != st.dismissedZip {
                busy = true
                q.async { Thread.sleep(forTimeInterval: 2); self.engine.promptRestore(autoDismiss: true)
                    DispatchQueue.main.async { self.busy = false } }
            }
        } else if !now && wasRunning {                            // QUIT edge
            if !FileManager.default.fileExists(atPath: engine.stateDir + "/restoring.lock") {
                busy = true
                q.async { self.engine.backup(); DispatchQueue.main.async { self.busy = false } }
            }
        }
        wasRunning = now
    }

    // ---- actions ----
    @objc func doBackup() { busy = true; q.async { self.engine.backup(force: true); DispatchQueue.main.async { self.busy = false } } }
    @objc func doRestore() { busy = true; q.async { self.engine.promptRestore(); DispatchQueue.main.async { self.busy = false } } }
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
