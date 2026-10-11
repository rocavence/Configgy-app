import AppKit

/// The Zen browser profile: preferences, extensions, themes and workspaces.
/// Never cookies, saved passwords, form history, certificates, or session dumps.
struct ZenTarget: BackupTarget {
    let context: Context
    let store: SnapshotStore
    /// The default profile folder, or nil when Zen isn't set up here.
    let profile: String?

    let key = "zen"
    let name = "Zen Browser"
    static let bundleID = "app.zen-browser.zen"
    var bundleID: String? { Self.bundleID }
    var appToClose: (bundleID: String, name: String)? { (Self.bundleID, "Zen") }

    /// Profile files that are settings, workspaces or extension lists.
    static let files = [
        "prefs.js", "user.js", "zen-themes.json", "zen-keyboard-shortcuts.json",
        "zen-boosts.jsonlz4", "zen-sessions.jsonlz4", "zen-space-routing.jsonlz4", "zen-live-folders.jsonlz4",
        "containers.json", "xulstore.json", "search.json.mozlz4", "handlers.json",
        "extensions.json", "addonStartup.json.lz4", "compatibility.ini",
    ]
    /// Profile folders copied whole (minus secrets): your CSS and installed extensions.
    static let folders = ["chrome", "extensions"]
    /// What "workspaces only" restores: workspaces and tabs, plus the containers they use.
    static let workspaceFiles: Set<String> = ["zen-sessions.jsonlz4", "zen-space-routing.jsonlz4", "containers.json"]

    init(context: Context, base: String, keep: Int) {
        self.context = context
        store = SnapshotStore(directory: base + "/zen", prefix: "configgy-zen-", legacyPrefixes: ["zennly-"], host: context.host, keep: keep)
        profile = Self.detectProfile(home: context.home)
    }

    static func root(home: String) -> String { home + "/Library/Application Support/zen" }

    /// The default profile from installs.ini (or profiles.ini). Nil if it can't
    /// be found, so nothing is ever written into Zen's root folder.
    static func detectProfile(home: String) -> String? {
        let root = root(home: home)
        let fm = FileManager.default
        var candidates: [String] = []
        if let text = try? String(contentsOfFile: root + "/installs.ini", encoding: .utf8) {
            candidates += text.split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("Default=") }
                .map { root + "/" + $0.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        }
        if let text = try? String(contentsOfFile: root + "/profiles.ini", encoding: .utf8) {
            for block in text.components(separatedBy: "\n[") where block.contains("Default=1") {
                let relative = block.contains("IsRelative=1")
                for line in block.split(whereSeparator: \.isNewline) where line.hasPrefix("Path=") {
                    let path = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    candidates.append(relative ? root + "/" + path : path)
                }
            }
        }
        return candidates.first { path in
            var isDir: ObjCBool = false
            return path != root + "/" && path != root && fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    static func includes(_ rel: String) -> Bool {
        guard !Sensitive.isSensitive(rel) else { return false }
        let parts = rel.split(separator: "/").map(String.init)
        guard let first = parts.first else { return false }
        return parts.count == 1 ? files.contains(first) : folders.contains(first)
    }

    func stage(into snapshot: String) throws {
        guard let profile else { throw ConfiggyError.notFound(String(localized: "a Zen profile")) }
        let count = try FileCopy.tree(profile, to: snapshot + "/profile", include: Self.includes)
        guard count > 0 else { throw ConfiggyError.nothingToBackUp }
        try Self.restoreScript.write(toFile: snapshot + "/restore.sh", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: snapshot + "/restore.sh")
    }

    func restorePlan(from snapshot: String) throws -> RestorePlan {
        try restorePlan(from: snapshot, only: nil)
    }

    /// A full restore, or only `workspaceFiles` when `only` is given.
    func restorePlan(from snapshot: String, only: Set<String>?) throws -> RestorePlan {
        guard let profile else { throw ConfiggyError.notFound(String(localized: "a Zen profile")) }
        let source = snapshot + "/profile"
        guard FileManager.default.fileExists(atPath: source) else { throw ConfiggyError.badSnapshot(String(localized: "it has no profile folder")) }
        var plan = RestorePlan()
        for rel in FileCopy.files(under: source) {
            if let only, !only.contains(rel) { continue }
            if Self.includes(rel) {
                plan.writes.append(.init(source: source + "/" + rel, destination: profile + "/" + rel))
            } else {
                plan.rejected.append(rel)
            }
        }
        return plan
    }

    /// Workspaces and tab counts from the staged session file, for the snapshot's description.
    static func summary(of snapshot: String) -> ZenSummary? {
        guard let data = FileManager.default.contents(atPath: snapshot + "/profile/zen-sessions.jsonlz4"),
              let json = ZenWorkspaces.decode(data) else { return nil }
        let spaces = json["spaces"] as? [[String: Any]] ?? []
        let tabs = json["tabs"] as? [[String: Any]] ?? []
        return ZenSummary(workspaces: spaces.map(ZenWorkspaces.label),
                          tabs: tabs.count,
                          pinned: tabs.filter { $0["pinned"] as? Bool == true }.count,
                          essentials: tabs.filter { $0["zenEssential"] as? Bool == true }.count)
    }

    /// Restores a snapshot on a Mac without Configgy: `sh restore.sh` from the
    /// unzipped folder. `${VAR:?}` stops the script instead of touching the
    /// wrong place if a path ever comes out empty.
    static let restoreScript = """
        #!/bin/sh
        # Restore this Zen backup without Configgy. Quit Zen first.
        set -eu
        HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/profile"
        [ -d "$SRC" ] || { echo "no profile/ next to restore.sh"; exit 1; }
        ROOT="$HOME/Library/Application Support/zen"
        ID="$(grep -m1 '^Default=' "$ROOT/installs.ini" 2>/dev/null | cut -d= -f2 || true)"
        [ -n "$ID" ] || { echo "no default profile in $ROOT/installs.ini; open Zen once, then try again"; exit 1; }
        P="$ROOT/$ID"
        [ -d "$P" ] || { echo "profile folder not found: $P"; exit 1; }
        if pgrep -f "Zen.app/Contents/MacOS/zen" >/dev/null 2>&1; then echo "quit Zen first"; exit 1; fi
        BK="$P/pre-restore-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
        ( cd "$SRC" && find . -mindepth 1 -maxdepth 1 ) | while read -r i; do
          n=$(basename "$i")
          if [ -e "${P:?}/${n:?}" ]; then cp -Rp "${P:?}/${n:?}" "$BK/"; rm -rf "${P:?}/${n:?}"; fi
          cp -Rp "$SRC/$n" "$P/"
        done
        echo "restored into $P (previous files in $BK)"
        """

    @MainActor
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// Reading and merging Zen's workspaces (spaces) and tabs.
enum ZenWorkspaces {
    static func decode(_ data: Data) -> [String: Any]? {
        MozLz4.decode(data).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func label(_ space: [String: Any]) -> String {
        "\(space["icon"] as? String ?? "") \(space["name"] as? String ?? "")".trimmingCharacters(in: .whitespaces)
    }

    /// The workspaces in an unpacked snapshot, as (uuid, label).
    static func list(in snapshot: String) -> [(uuid: String, label: String)] {
        guard let data = FileManager.default.contents(atPath: snapshot + "/profile/zen-sessions.jsonlz4"),
              let json = decode(data) else { return [] }
        return (json["spaces"] as? [[String: Any]] ?? []).compactMap { space in
            guard let uuid = space["uuid"] as? String, !uuid.isEmpty else { return nil }
            let text = label(space)
            return (uuid, text.isEmpty ? uuid : text)
        }
    }

    /// Writes merged copies of the live session and containers files into
    /// `output` — the chosen workspaces (and their tabs and containers) from the
    /// snapshot replace or join the live ones — and returns the plan that puts them in place.
    static func mergePlan(snapshot: String, profile: String, uuids: Set<String>, output: String) throws -> RestorePlan {
        let fm = FileManager.default
        guard let backup = fm.contents(atPath: snapshot + "/profile/zen-sessions.jsonlz4").flatMap(decode) else {
            throw ConfiggyError.badSnapshot(String(localized: "its workspaces can't be read"))
        }
        guard var live = fm.contents(atPath: profile + "/zen-sessions.jsonlz4").flatMap(decode) else {
            throw ConfiggyError.badSnapshot(String(localized: "Zen's current workspaces can't be read"))
        }
        let chosenSpaces = (backup["spaces"] as? [[String: Any]] ?? []).filter { uuids.contains($0["uuid"] as? String ?? "") }
        let chosenTabs = (backup["tabs"] as? [[String: Any]] ?? []).filter { uuids.contains($0["zenWorkspace"] as? String ?? "") }
        guard !chosenSpaces.isEmpty else { throw ConfiggyError.badSnapshot(String(localized: "the chosen workspaces aren't in it")) }

        var spaces = live["spaces"] as? [[String: Any]] ?? []
        var tabs = live["tabs"] as? [[String: Any]] ?? []
        spaces.removeAll { uuids.contains($0["uuid"] as? String ?? "") }
        tabs.removeAll { uuids.contains($0["zenWorkspace"] as? String ?? "") }
        live["spaces"] = spaces + chosenSpaces
        live["tabs"] = tabs + chosenTabs

        try fm.createDirectory(atPath: output, withIntermediateDirectories: true)
        let sessions = output + "/zen-sessions.jsonlz4"
        try MozLz4.encode(try JSONSerialization.data(withJSONObject: live)).write(to: URL(fileURLWithPath: sessions))
        var plan = RestorePlan(writes: [.init(source: sessions, destination: profile + "/zen-sessions.jsonlz4")])

        // Containers the chosen workspaces and tabs use, if this Mac lacks them.
        var used = Set<Int>()
        for space in chosenSpaces { if let id = space["containerTabId"] as? Int, id != 0 { used.insert(id) } }
        for tab in chosenTabs { if let id = tab["userContextId"] as? Int, id != 0 { used.insert(id) } }
        if !used.isEmpty,
           let backupContainers = fm.contents(atPath: snapshot + "/profile/containers.json").flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }),
           let identities = backupContainers["identities"] as? [[String: Any]],
           var liveContainers = fm.contents(atPath: profile + "/containers.json").flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }) {
            var liveIdentities = liveContainers["identities"] as? [[String: Any]] ?? []
            let existing = Set(liveIdentities.compactMap { $0["userContextId"] as? Int })
            let missing = identities.filter { ($0["userContextId"] as? Int).map { used.contains($0) && !existing.contains($0) } ?? false }
            if !missing.isEmpty {
                liveIdentities += missing
                liveContainers["identities"] = liveIdentities
                let containers = output + "/containers.json"
                try JSONSerialization.data(withJSONObject: liveContainers).write(to: URL(fileURLWithPath: containers))
                plan.writes.append(.init(source: containers, destination: profile + "/containers.json"))
            }
        }
        return plan
    }
}
