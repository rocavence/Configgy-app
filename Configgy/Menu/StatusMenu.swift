import AppKit

/// The menu-bar icon and its short menu; everything else is in the window.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    var openWindow: () -> Void = {}
    var openSettings: () -> Void = {}
    private var revert: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        setIcon(.idle)
    }

    func setIcon(_ activity: AppModel.Activity) {
        revert?.cancel()
        guard let button = statusItem.button else { return }
        button.layer?.removeAllAnimations()
        switch activity {
        case .idle:
            button.image = Icon.nsImage(.boxTime, size: 18)
            button.contentTintColor = nil
        case .working:
            button.image = Icon.nsImage(.boxTime, weight: .filled, size: 18)
            button.contentTintColor = nil
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                button.wantsLayer = true
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1; pulse.toValue = 0.35; pulse.duration = 0.6
                pulse.autoreverses = true; pulse.repeatCount = .infinity
                button.layer?.add(pulse, forKey: "pulse")
            }
        case .succeeded:
            button.image = Icon.nsImage(.boxTick, weight: .filled, size: 18)
            button.contentTintColor = .systemGreen
            revertSoon(after: 1.8)
        case .failed:
            button.image = Icon.nsImage(.danger, weight: .filled, size: 18)
            button.contentTintColor = .systemRed
            revertSoon(after: 4)
        }
        button.setAccessibilityLabel("Configgy, " + summary)
    }

    private func revertSoon(after seconds: Double) {
        revert = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            setIcon(.idle)
        }
    }

    private var summary: String {
        switch model.location {
        case .notChosen: return String(localized: "Choose where to keep backups")
        case .missing: return String(localized: "Backup folder not found")
        case .notWritable: return String(localized: "Needs Full Disk Access")
        case .ok: break
        }
        let n = model.rows.filter { $0.health != .protected }.count
        return n == 0 ? String(localized: "Everything is backed up") : String(localized: "\(n) need attention")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if case .notWritable = model.location {
            menu.addItem(item(String(localized: "Grant Full Disk Access…"), #selector(grantAccess), image: .warning))
        }
        if let release = model.updates.available {
            menu.addItem(item(String(localized: "Configgy \(release.version) is available. Download…"), #selector(openUpdate)))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Open Configgy…"), #selector(showWindow), key: "o"))
        menu.addItem(item(String(localized: "Back Up Everything Now"), #selector(backupAll)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), #selector(showSettings), key: ","))
        menu.addItem(item(String(localized: "Quit Configgy"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", image: Reicon? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let image { item.image = Icon.nsImage(image, size: 14) }
        return item
    }

    @objc private func showWindow() { openWindow() }
    @objc private func showSettings() { openSettings() }
    @objc private func backupAll() { Task { await model.backupAll() } }
    @objc private func grantAccess() { model.openFullDiskAccess() }
    @objc private func openUpdate() { NSWorkspace.shared.open(model.updates.available?.page ?? UpdateChecker.releases) }
    @objc private func quit() { NSApp.terminate(nil) }
}
