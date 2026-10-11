import Foundation

/// Where Configgy works: whose home, which backup folder, which machine. Every
/// file operation takes one, so tests and the self-test run against a fake
/// home and a fake cloud folder.
struct Context: Sendable {
    let home: String
    /// The "Configgy" folder inside the cloud folder (holds zen/, claude/, targets/), or nil when not chosen yet.
    let base: String?
    let host: String

    var supportDir: String { home + "/Library/Application Support/Configgy" }

    /// The real one: $CONFIGGY_HOME (self-test) or the user's home.
    static func current() -> Context {
        let env = ProcessInfo.processInfo.environment
        let home = env["CONFIGGY_HOME"] ?? env["HOME"] ?? NSHomeDirectory()
        return Context(home: home, base: BackupLocation.resolve(home: home), host: env["CONFIGGY_HOST"] ?? detectHost())
    }

    func with(base: String?) -> Context { Context(home: home, base: base, host: host) }

    /// The user-set computer name ("Roca-MBP"), kept to letters, digits, - and _.
    /// Snapshot names carry it, and retention counts per host.
    static func detectHost() -> String {
        var name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name = String(name.dropLast(6)) }
        let cleaned = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cleaned.isEmpty ? "mac" : cleaned
    }

    /// `~/x` → `/Users/me/x`.
    func expand(_ path: String) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
    }

    /// `/Users/me/x` → `~/x`; paths outside the home are kept absolute.
    func abbreviate(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

enum ConfiggyError: LocalizedError {
    case noLocation
    case locationUnavailable(String)
    case nothingToBackUp
    case appRunning(String)
    case badSnapshot(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .noLocation:
            String(localized: "No backup folder has been chosen yet.")
        case .locationUnavailable(let path):
            String(localized: "The backup folder isn't available: \(path). Check that the cloud app is running, or choose another folder.")
        case .nothingToBackUp:
            String(localized: "None of this target's files exist on this Mac.")
        case .appRunning(let name):
            String(localized: "\(name) is still open. Quit it first.")
        case .badSnapshot(let reason):
            String(localized: "This backup can't be used: \(reason)")
        case .notFound(let name):
            String(localized: "Couldn't find \(name).")
        }
    }
}
