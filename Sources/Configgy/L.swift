import Foundation

// Tiny in-code localization (no .lproj needed for the hand-assembled bundle).
// Follows the system language by default; an explicit "zh"/"en" override wins.
enum L {
    enum Lang: String { case zh, en }
    static var lang: Lang = resolve(nil)

    static func resolve(_ override: String?) -> Lang {
        if let o = override, let l = Lang(rawValue: o) { return l }
        let sys = (Locale.preferredLanguages.first ?? "en").lowercased()
        return sys.hasPrefix("zh") ? .zh : .en
    }
    static func t(_ zh: String, _ en: String) -> String { lang == .zh ? zh : en }
}
