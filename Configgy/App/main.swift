import AppKit

// `Configgy <command>` runs headless and exits; with no command it's the
// menu-bar app. Arguments starting with "-" are AppKit's (-AppleLanguages…).
let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, !first.hasPrefix("-"), ProcessInfo.processInfo.environment["CONFIGGY_SELFTEST"] == nil {
    exit(CLI.run(arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
