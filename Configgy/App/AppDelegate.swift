import AppKit

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
            SelfTest.run(item)
            return
        }
        #endif

        let model = AppModel()
        let menu = StatusMenu(model: model)
        let main = MainWindow(model: model)
        let settings = SettingsWindow(model: model)
        main.openSettings = { settings.show(.general) }
        menu.openWindow = { main.show() }
        menu.openSettings = { settings.show(.general) }
        settings.showGuide = { [weak self] in self?.showOnboarding() }
        model.onActivity = { menu.setIcon($0) }
        model.start()
        self.model = model
        self.menu = menu
        self.main = main
        self.settings = settings
        if !model.settings.onboarded { showOnboarding() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        main?.show()
        return true
    }

    private func showOnboarding() {
        guard let model else { return }
        let window = OnboardingWindow(model: model)
        window.onFinish = { [weak self] in self?.main?.show() }
        window.show()
        onboarding = window
    }
}
