import Foundation

/// A command that exited with a non-zero status.
struct CommandError: LocalizedError {
    let command: String
    let status: Int32
    let output: String

    var errorDescription: String? {
        let tail = output.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
        return "\(command) exited with \(status)" + (tail.isEmpty ? "" : ": \(tail)")
    }
}

/// The one way Configgy runs `zip`, `unzip` and friends: every exit status is
/// checked, so a failure stops the operation instead of passing silently.
enum Shell {
    /// Runs to completion and returns stdout; throws `CommandError` on a non-zero exit.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], cwd: String? = nil) throws -> Data {
        let (status, out, err) = execute(path, arguments, cwd: cwd)
        guard status == 0 else {
            let name = (path as NSString).lastPathComponent
            throw CommandError(command: name, status: status, output: String(decoding: err.isEmpty ? out : err, as: UTF8.self))
        }
        return out
    }

    /// Runs and reports only whether it exited 0 (for probes like `pgrep`).
    static func succeeds(_ path: String, _ arguments: [String]) -> Bool {
        execute(path, arguments, cwd: nil).status == 0
    }

    private static func execute(_ path: String, _ arguments: [String], cwd: String?) -> (status: Int32, out: Data, err: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, Data(), Data(error.localizedDescription.utf8)) }
        // Drain stderr concurrently so a chatty command can't fill its pipe and stall.
        nonisolated(unsafe) var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, outData, errData)
    }
}
