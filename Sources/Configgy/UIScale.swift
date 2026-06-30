import AppKit

// UI scale is a manual setting (Settings → Enlarge UI), default off (1.0).
// When on, the whole custom UI renders 1.1×.
enum UI {
    static var scale: CGFloat = compute()
    static func compute() -> CGFloat {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return Settings.load(home).uiZoom ? 1.1 : 1.0
    }
    static func s(_ v: CGFloat) -> CGFloat { (v * scale).rounded() }
    static func font(_ pt: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: pt * scale, weight: w) }
    static func symCfg(_ pt: CGFloat) -> NSImage.SymbolConfiguration { .init(pointSize: pt * scale, weight: .regular) }
}
