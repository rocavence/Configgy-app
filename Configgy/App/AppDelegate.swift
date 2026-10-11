import AppKit

/// The menu-bar app. Windows are built when opened and released when closed,
/// so the resident app is just the model and the status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var menu: StatusMenu?
    private var main: MainWindow?
    private var settings: SettingsWindow?
    private var onboarding: OnboardingWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        AppAppearance.apply(.saved)

        #if DEBUG
        if let item = ProcessInfo.processInfo.environment["CONFIGGY_SELFTEST"] {
            if item == "screenshots" { Screenshots.run() } else { SelfTest.run(item) }
            return
        }
        #endif

        let model = AppModel()
        let menu = StatusMenu(model: model)
        menu.openWindow = { [weak self] in self?.showMain() }
        menu.openSettings = { [weak self] in self?.showSettings() }
        model.onActivity = { menu.setIcon($0) }
        model.start()
        self.model = model
        self.menu = menu
        if !model.settings.onboarded { showOnboarding() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    private func showMain() {
        guard let model else { return }
        if main == nil {
            let window = MainWindow(model: model)
            window.openSettings = { [weak self] in self?.showSettings() }
            window.onClose = { [weak self] in
                self?.main = nil
                AppIcons.clear()
                Memory.relieve()
            }
            main = window
        }
        main?.show()
    }

    private func showSettings(_ page: SettingsPage = .general) {
        guard let model else { return }
        if settings == nil {
            let window = SettingsWindow(model: model)
            window.showGuide = { [weak self] in self?.showOnboarding() }
            window.onClose = { [weak self] in
                self?.settings = nil
                Memory.relieve()
            }
            settings = window
        }
        settings?.show(page)
    }

    private func showOnboarding() {
        guard let model else { return }
        let window = OnboardingWindow(model: model)
        window.onFinish = { [weak self] in self?.showMain() }
        window.onClose = { [weak self] in
            self?.onboarding = nil
            Memory.relieve()
        }
        window.show()
        onboarding = window
    }
}

/// Hands memory freed after heavy work (zip listings, file copies, closed
/// windows) back to the system instead of keeping it in the malloc zones.
enum Memory {
    static func relieve() {
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
    }
}
