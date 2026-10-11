import Foundation
import os

/// Every backup and restore is written to ~/Library/Logs/Configgy/configgy.log
/// (and the unified log), so a failure can be looked up afterwards.
enum Log {
    private static let logger = Logger(subsystem: "com.rocavence.configgy", category: "app")
    private static let lock = NSLock()

    static func directory(home: String) -> String { home + "/Library/Logs/Configgy" }
    static func file(home: String) -> String { directory(home: home) + "/configgy.log" }

    static func write(_ message: String, home: String, error: Bool = false) {
        if error { logger.error("\(message, privacy: .public)") } else { logger.notice("\(message, privacy: .public)") }
        if ProcessInfo.processInfo.environment["CONFIGGY_CLI"] != nil {
            FileHandle.standardError.write(Data("[configgy] \(message)\n".utf8))
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(error ? "ERROR" : "INFO ") \(message)\n"
        lock.lock(); defer { lock.unlock() }
        let dir = directory(home: home), path = file(home: home)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}
