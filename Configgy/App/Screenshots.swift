#if DEBUG
import AppKit
import SwiftUI

/// Website screenshots, driven by `scripts/screenshots.sh`. Builds a believable
/// fake home (two Macs, everything protected, a real change to preview), opens
/// each window for real, and asks the script — which has Screen Recording
/// access — to capture it with its frame and shadow. Nothing real is touched.
@MainActor
enum Screenshots {
    private static let fm = FileManager.default
    private static var root: String { ProcessInfo.processInfo.environment["CONFIGGY_HOME"]! }
    private static var home: String { root + "/home" }
    private static var cloud: String { home + "/Dropbox/Apps/Configgy" }
    private static var requests: String { ProcessInfo.processInfo.environment["CONFIGGY_SHOTS"]! }
    private static let host = "MacBook-Pro"
    private static var context: Context { Context(home: home, base: cloud, host: host) }

    static func run() {
        Task {
            do {
                try makeHome()
                let model = AppModel(context: context)
                model.refresh()
                try await Task.sleep(for: .seconds(1))

                let main = MainWindow(model: model)
                main.nsWindow.appearance = NSAppearance(named: .darkAqua)
                main.nsWindow.setContentSize(NSSize(width: 760, height: 700))
                main.show(activate: true)
                try await capture(main.nsWindow, "main-dark")
                main.nsWindow.appearance = NSAppearance(named: .aqua)
                try await capture(main.nsWindow, "main-light")
                main.close()

                let claude = ClaudeTarget(context: context, base: cloud, keep: 10)
                let restore = panel(RestoreSheet(model: model, target: claude, initial: claude.store.newest()) {}, light: true)
                try await Task.sleep(for: .seconds(2))
                try await capture(restore, "restore-light")
                restore.close()

                let onboarding = OnboardingWindow(model: model)
                onboarding.show(activate: true)
                onboarding.nsWindow?.appearance = NSAppearance(named: .aqua)
                if let window = onboarding.nsWindow { try await capture(window, "onboarding-light") }
                onboarding.close()

                let settings = SettingsWindow(model: model)
                settings.nsWindow.appearance = NSAppearance(named: .darkAqua)
                settings.show(.exclusions, activate: true)
                try await capture(settings.nsWindow, "exclusions-dark")
                settings.close()
                print("SCREENSHOTS OK")
            } catch {
                print("SCREENSHOTS FAILED \(error.localizedDescription)")
            }
            exit(0)
        }
    }

    /// A sheet's content in a plain window, so it can be shot on its own.
    private static func panel<V: View>(_ view: V, light: Bool) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.contentView = NSHostingView(rootView: view.padding(.top, Spacing.s16).background(Palette.background))
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return window
    }

    /// Asks the script to capture `window`, then waits for the file.
    private static func capture(_ window: NSWindow, _ name: String) async throws {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(1200))
        fm.createFile(atPath: requests + "/\(name).request", contents: Data("\(window.windowNumber)".utf8))
        for _ in 0..<100 {
            if fm.fileExists(atPath: requests + "/\(name).png") { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("no capture for \(name)")
    }

    private static func makeHome() throws {
        try? fm.removeItem(atPath: root)
        let claude = home + "/.claude"
        let files: [String: String] = [
            claude + "/settings.json": "{\"theme\":\"dark\",\"model\":\"opus\"}",
            claude + "/CLAUDE.md": "# Working notes",
            claude + "/agents/reviewer.md": "reviewer",
            claude + "/commands/ship.md": "ship",
            claude + "/skills/release/SKILL.md": "release",
            claude + "/skills/review/SKILL.md": "review",
            claude + "/hooks/format.sh": "format",
            claude + "/agents/planner.md": "planner",
            claude + "/projects/site/memory/notes.md": "memory",
            home + "/.zshrc": "export EDITOR=zed",
            home + "/.gitconfig": "[user]\n\tname = Roca",
            home + "/Library/Application Support/zen/installs.ini": "[Install]\nDefault=Profiles/abc.default\n",
            home + "/Library/Application Support/zen/Profiles/abc.default/prefs.js": "user_pref(\"a\", 1);",
        ]
        for (path, text) in files {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: Data(text.utf8))
        }
        var settings = ConfiggySettings()
        settings.backupBase = cloud
        settings.zenEnabled = true
        settings.onboarded = true
        settings.save(home)
        TargetCatalog.save([
            TargetCatalog.suggestions.first { $0.def.id == "shell" }!.def,
            TargetCatalog.suggestions.first { $0.def.id == "git" }!.def,
        ], home: home)

        // Older history from both Macs, then a real Claude backup, then a change to preview.
        let now = Date()
        func seed(_ dir: String, _ prefix: String, _ host: String, _ days: [Double], files: Int) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for d in days {
                let date = now.addingTimeInterval(-d * 86_400)
                let ts = SnapshotStore.stamp(date)
                let path = dir + "/\(prefix)\(host)-\(ts).zip"
                fm.createFile(atPath: path, contents: Data())
                let meta = SnapshotMeta(host: host, ts: ts, iso: ISO8601DateFormatter().string(from: date), hash: UUID().uuidString, files: files)
                try? JSONEncoder().encode(meta).write(to: URL(fileURLWithPath: path + ".json"))
            }
        }
        seed(cloud + "/claude", "configgy-claude-", host, [2.2, 5, 9], files: 46)
        seed(cloud + "/claude", "configgy-claude-", "Mac-mini", [3.5, 12], files: 44)
        seed(cloud + "/zen", "configgy-zen-", host, [0.3, 1.4, 2.6, 4, 7], files: 312)
        seed(cloud + "/zen", "configgy-zen-", "Mac-mini", [1.9, 6], files: 305)
        seed(cloud + "/targets/shell", "configgy-shell-", host, [0.8, 6], files: 3)
        seed(cloud + "/targets/git", "configgy-git-", host, [0.8, 15], files: 2)
        _ = try BackupService.backup(ClaudeTarget(context: context, base: cloud, keep: 10), context: context)
        try Data("{\"theme\":\"light\",\"model\":\"sonnet\"}".utf8).write(to: URL(fileURLWithPath: claude + "/settings.json"))
        try Data("# Working notes (edited)".utf8).write(to: URL(fileURLWithPath: claude + "/CLAUDE.md"))
        try? fm.removeItem(atPath: claude + "/commands/ship.md")
        try? fm.removeItem(atPath: claude + "/skills/review/SKILL.md")
        try Data("reviewer, stricter".utf8).write(to: URL(fileURLWithPath: claude + "/agents/reviewer.md"))
        try Data("release v2".utf8).write(to: URL(fileURLWithPath: claude + "/skills/release/SKILL.md"))
        try Data("memory, updated".utf8).write(to: URL(fileURLWithPath: claude + "/projects/site/memory/notes.md"))
        try Data("format --fix".utf8).write(to: URL(fileURLWithPath: claude + "/hooks/format.sh"))
    }
}
#endif
