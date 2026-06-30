import Foundation

// A common config location Configgy can offer to back up (apps without their own
// cloud sync). Conservative + secret-free by default.
struct DiscoveryItem { let id: String; let name: String; let paths: [String]; let excludes: [String]; let note: String; var app: String? = nil }

enum TargetStore {
    static func dirPath(_ home: String) -> String { home + "/Library/Application Support/Configgy" }
    static func filePath(_ home: String) -> String { dirPath(home) + "/targets.json" }

    static func load(_ home: String) -> [TargetDef] {
        guard let d = FileManager.default.contents(atPath: filePath(home)),
              let defs = try? JSONDecoder().decode([TargetDef].self, from: d) else { return [] }
        return defs
    }
    static func save(_ defs: [TargetDef], home: String) {
        try? FileManager.default.createDirectory(atPath: dirPath(home), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(defs) { try? d.write(to: URL(fileURLWithPath: filePath(home))) }
    }
    static func add(_ def: TargetDef, home: String) {
        var defs = load(home); defs.removeAll { $0.id == def.id }; defs.append(def); save(defs, home: home)
    }
    static func remove(_ id: String, home: String) {
        var defs = load(home); defs.removeAll { $0.id == id }; save(defs, home: home)
    }

    // built-in catalog of common, sync-less, secret-free config locations
    static let catalog: [DiscoveryItem] = [
        DiscoveryItem(id: "shell", name: "Shell 設定", paths: ["~/.zshrc", "~/.zprofile", "~/.zshenv", "~/.bashrc", "~/.bash_profile", "~/.profile", "~/.inputrc", "~/.aliases"], excludes: [], note: "zsh/bash 啟動檔"),
        DiscoveryItem(id: "git", name: "Git 設定", paths: ["~/.gitconfig", "~/.gitignore_global", "~/.config/git"], excludes: [], note: ""),
        DiscoveryItem(id: "ssh-config", name: "SSH config（不含金鑰）", paths: ["~/.ssh/config"], excludes: [], note: "只 config，私鑰不備"),
        DiscoveryItem(id: "tmux", name: "tmux", paths: ["~/.tmux.conf"], excludes: [], note: ""),
        DiscoveryItem(id: "vim", name: "Vim / Neovim", paths: ["~/.vimrc", "~/.config/nvim"], excludes: [".git/"], note: ""),
        DiscoveryItem(id: "zed", name: "Zed 編輯器", paths: ["~/.config/zed"], excludes: [], note: "Zed 無內建雲端同步", app: "dev.zed.Zed"),
        DiscoveryItem(id: "vscode", name: "VS Code 設定", paths: ["~/Library/Application Support/Code/User/settings.json", "~/Library/Application Support/Code/User/keybindings.json", "~/Library/Application Support/Code/User/snippets"], excludes: [], note: "", app: "com.microsoft.VSCode"),
        DiscoveryItem(id: "terminals", name: "終端機設定", paths: ["~/.config/ghostty", "~/.config/alacritty", "~/.config/kitty", "~/.wezterm.lua"], excludes: [], note: ""),
        DiscoveryItem(id: "starship", name: "Starship prompt", paths: ["~/.config/starship.toml"], excludes: [], note: ""),
        DiscoveryItem(id: "karabiner", name: "Karabiner", paths: ["~/.config/karabiner"], excludes: [], note: "", app: "org.pqrs.Karabiner-Elements"),
        DiscoveryItem(id: "hammerspoon", name: "Hammerspoon", paths: ["~/.hammerspoon"], excludes: [".git/"], note: "", app: "org.hammerspoon.Hammerspoon"),
        DiscoveryItem(id: "gh", name: "GitHub CLI 設定（不含 token）", paths: ["~/.config/gh"], excludes: ["hosts.yml"], note: "排除含 token 的 hosts.yml"),
        // menubar / utility apps with no cloud sync — each listed individually
        DiscoveryItem(id: "monitorcontrol", name: "MonitorControl", paths: ["~/Library/Preferences/app.monitorcontrol.MonitorControl.plist"], excludes: [], note: "", app: "app.monitorcontrol.MonitorControl"),
        DiscoveryItem(id: "moom", name: "Moom", paths: ["~/Library/Preferences/com.manytricks.Moom.plist"], excludes: [], note: "", app: "com.manytricks.Moom"),
        DiscoveryItem(id: "iina", name: "IINA", paths: ["~/Library/Preferences/com.colliderli.iina.plist"], excludes: [], note: "", app: "com.colliderli.iina"),
        DiscoveryItem(id: "input-source-pro", name: "Input Source Pro", paths: ["~/Library/Preferences/com.runjuu.Input-Source-Pro.plist"], excludes: [], note: "", app: "com.runjuu.Input-Source-Pro"),
        DiscoveryItem(id: "rectangle", name: "Rectangle", paths: ["~/Library/Preferences/com.knollsoft.Rectangle.plist"], excludes: [], note: "", app: "com.knollsoft.Rectangle"),
        DiscoveryItem(id: "mac-mouse-fix", name: "Mac Mouse Fix", paths: ["~/Library/Preferences/com.nuebling.mac-mouse-fix.plist", "~/Library/Preferences/com.nuebling.mac-mouse-fix.helper.plist"], excludes: [], note: "", app: "com.nuebling.mac-mouse-fix"),
        DiscoveryItem(id: "motrix", name: "Motrix", paths: ["~/Library/Preferences/app.motrix.native.plist"], excludes: [], note: "", app: "net.agalwood.Motrix"),
        DiscoveryItem(id: "mole", name: "Mole", paths: ["~/Library/Preferences/com.tw93.MoleApp.plist"], excludes: [], note: "", app: "com.tw93.MoleApp"),
        DiscoveryItem(id: "otty", name: "Otty", paths: ["~/Library/Preferences/io.appmakes.otty.plist"], excludes: [], note: "", app: "io.appmakes.otty"),
        DiscoveryItem(id: "subler", name: "Subler", paths: ["~/Library/Preferences/org.galad.Subler.plist"], excludes: [], note: "", app: "org.galad.Subler"),
        DiscoveryItem(id: "upscayl", name: "Upscayl", paths: ["~/Library/Preferences/org.upscayl.Upscayl.plist"], excludes: [], note: "", app: "org.upscayl.Upscayl"),
        DiscoveryItem(id: "gamely", name: "Gamely", paths: ["~/Library/Preferences/com.gamely.app.plist"], excludes: [], note: "", app: "com.gamely.app"),
    ]
    static func discover(_ home: String) -> [DiscoveryItem] {
        let fm = FileManager.default
        func ex(_ p: String) -> String { p.hasPrefix("~") ? home + String(p.dropFirst()) : p }
        return catalog.filter { item in item.paths.contains { fm.fileExists(atPath: ex($0)) } }
    }
}
