import Foundation

// A common config location Configgy can offer to back up (apps without their own
// cloud sync). Conservative + secret-free by default.
struct DiscoveryItem { let id: String; let name: String; let paths: [String]; let excludes: [String]; let note: String }

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
        DiscoveryItem(id: "zed", name: "Zed 編輯器", paths: ["~/.config/zed"], excludes: [], note: "Zed 無內建雲端同步"),
        DiscoveryItem(id: "vscode", name: "VS Code 設定", paths: ["~/Library/Application Support/Code/User/settings.json", "~/Library/Application Support/Code/User/keybindings.json", "~/Library/Application Support/Code/User/snippets"], excludes: [], note: ""),
        DiscoveryItem(id: "terminals", name: "終端機設定", paths: ["~/.config/ghostty", "~/.config/alacritty", "~/.config/kitty", "~/.wezterm.lua"], excludes: [], note: ""),
        DiscoveryItem(id: "starship", name: "Starship prompt", paths: ["~/.config/starship.toml"], excludes: [], note: ""),
        DiscoveryItem(id: "karabiner", name: "Karabiner", paths: ["~/.config/karabiner"], excludes: [], note: ""),
        DiscoveryItem(id: "hammerspoon", name: "Hammerspoon", paths: ["~/.hammerspoon"], excludes: [".git/"], note: ""),
        DiscoveryItem(id: "gh", name: "GitHub CLI 設定（不含 token）", paths: ["~/.config/gh"], excludes: ["hosts.yml"], note: "排除含 token 的 hosts.yml"),
        // menubar / utility apps with no cloud sync — each listed individually
        DiscoveryItem(id: "monitorcontrol", name: "MonitorControl", paths: ["~/Library/Preferences/app.monitorcontrol.MonitorControl.plist"], excludes: [], note: ""),
        DiscoveryItem(id: "moom", name: "Moom", paths: ["~/Library/Preferences/com.manytricks.Moom.plist"], excludes: [], note: ""),
        DiscoveryItem(id: "iina", name: "IINA", paths: ["~/Library/Preferences/com.colliderli.iina.plist"], excludes: [], note: ""),
        DiscoveryItem(id: "input-source-pro", name: "Input Source Pro", paths: ["~/Library/Preferences/com.runjuu.Input-Source-Pro.plist"], excludes: [], note: ""),
        DiscoveryItem(id: "rectangle", name: "Rectangle", paths: ["~/Library/Preferences/com.knollsoft.Rectangle.plist"], excludes: [], note: ""),
        DiscoveryItem(id: "mac-mouse-fix", name: "Mac Mouse Fix", paths: ["~/Library/Preferences/com.nuebling.mac-mouse-fix.plist"], excludes: [], note: ""),
    ]
    static func discover(_ home: String) -> [DiscoveryItem] {
        let fm = FileManager.default
        func ex(_ p: String) -> String { p.hasPrefix("~") ? home + String(p.dropFirst()) : p }
        return catalog.filter { item in item.paths.contains { fm.fileExists(atPath: ex($0)) } }
    }
}
