import AppKit

// On a 3K-or-wider display, scale the whole custom UI (sizes + fonts) 1.5×.
enum UI {
    static let scale: CGFloat = {
        guard let s = NSScreen.main else { return 1 }
        let px = s.frame.width * s.backingScaleFactor          // physical pixel width
        return px >= 3000 ? 1.2 : 1.0
    }()
    static func s(_ v: CGFloat) -> CGFloat { (v * scale).rounded() }
    static func font(_ pt: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: pt * scale, weight: w) }
    static func symCfg(_ pt: CGFloat) -> NSImage.SymbolConfiguration { .init(pointSize: pt * scale, weight: .regular) }
}
