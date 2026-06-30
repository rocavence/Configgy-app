import Foundation

// What a restore would change, computed by comparing a snapshot's files against
// the live target. Restores here are additive/replace (never delete live-only
// files), so there's no "removed" set.
struct ChangeSet {
    var modified: [String] = []
    var added: [String] = []
    var isEmpty: Bool { modified.isEmpty && added.isEmpty }
    var count: Int { modified.count + added.count }
}

enum ConfigDiff {
    // Files present in `snapshot` compared to `live` (recursive, by content).
    static func compare(snapshot: String, live: String) -> ChangeSet {
        let fm = FileManager.default
        var cs = ChangeSet()
        guard let en = fm.enumerator(atPath: snapshot) else { return cs }
        for case let rel as String in en {
            let sp = snapshot + "/" + rel
            var isDir: ObjCBool = false
            fm.fileExists(atPath: sp, isDirectory: &isDir)
            if isDir.boolValue { continue }
            let lp = live + "/" + rel
            if !fm.fileExists(atPath: lp) { cs.added.append(rel); continue }
            if !sameContent(sp, lp) { cs.modified.append(rel) }
        }
        cs.added.sort(); cs.modified.sort()
        return cs
    }

    private static func sameContent(_ a: String, _ b: String) -> Bool {
        let fm = FileManager.default
        let sa = (try? fm.attributesOfItem(atPath: a))?[.size] as? Int
        let sb = (try? fm.attributesOfItem(atPath: b))?[.size] as? Int
        if sa != sb { return false }                  // different size → changed (cheap)
        guard let da = fm.contents(atPath: a), let db = fm.contents(atPath: b) else { return false }
        return da == db
    }
}
