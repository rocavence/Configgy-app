import Foundation

/// The secret filter: names Configgy never copies into a backup, whatever the
/// target, and never writes back from an old backup that still has them.
enum Sensitive {
    /// File names (glob, case-insensitive) that hold credentials or browsing secrets.
    static let filePatterns = [
        ".credentials.json", "*credential*", "*token*", "*secret*",
        ".env", ".env.*", "*.env", "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*",
        "*.pem", "*.key", "*.p12", "*.pfx", "*.keychain*", ".netrc", ".npmrc", ".pypirc",
        "cookies.sqlite*", "logins.json", "logins-backup.json", "key3.db", "key4.db",
        "formhistory.sqlite*", "cert9.db", "signedInUser.json",
        "history.jsonl", "*.sqlite-wal", "*.sqlite-shm",
    ]

    /// Folder names whose whole contents are skipped: secrets, session dumps, or rebuildable junk.
    static let directoryPatterns = [
        ".git", "node_modules", ".venv", "venv", "*-venv", "__pycache__", ".cache",
        "sessionstore-backups", "zen-sessions-backup", "sessions", "session-env", "shell-snapshots",
    ]

    /// Starting excludes for custom folders; editable in Settings › Exclusions.
    static let defaultFolderExcludes = [
        ".env*", "id_*", "*.pem", "*.key", ".netrc", ".npmrc", ".pypirc", "*token*", "*credential*",
        ".git/", "node_modules/", ".venv/", "venv/",
    ]

    /// Whether a relative path inside a backup is a secret (or under a skipped folder).
    static func isSensitive(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        if parts.dropLast().contains(where: { matchesAny($0, directoryPatterns) }) { return true }
        return matchesAny(name, filePatterns)
    }

    /// Whether a path matches one of the user's folder excludes; a trailing `/`
    /// means "a folder with this name, anywhere".
    static func isExcluded(_ relativePath: String, by patterns: [String]) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        for pattern in patterns {
            if pattern.hasSuffix("/") {
                let dir = String(pattern.dropLast())
                if parts.dropLast().contains(where: { glob(dir, $0) }) { return true }
            } else if glob(pattern, name) {
                return true
            }
        }
        return false
    }

    static func matchesAny(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { glob($0, name) }
    }

    static func glob(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
    }
}
