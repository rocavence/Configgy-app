<p align="center">
  <img src="Resources/icon-256.png" width="128" alt="Configgy icon">
</p>

<h1 align="center">Configgy</h1>

<p align="center">
  一個小巧的 macOS <b>選單列 App</b>，把你本機的設定備份起來、跨裝置還原 ——
  目前支援 <b>Zen Browser</b>、<b>Claude Code</b>，以及任意自訂資料夾。
</p>

<p align="center"><a href="README.md">English</a> · <b>繁體中文</b></p>

---

## 功能

Configgy 安靜地待在選單列，把那些「不想丟、又沒地方雲端同步」的設定做成版本化、可攜的備份。三種目標、兩種機制：

| 目標 | 位置 | 方式 | 觸發 |
|---|---|---|---|
| **Zen Browser** | `Apps/Configgy/zen/` | 版本化 `.zip` 快照（留 10 份、內容去重） | 關閉 Zen 時**自動** |
| **Claude Code** | `Apps/Configgy/claude/` | 版本化 `.zip` 快照（留 10 份、內容去重） | **手動**（選單） |
| **自訂／自動發現** | `Apps/Configgy/targets/<id>/` | 版本化 `.zip` 快照（保留絕對路徑） | **手動**（選單） |

> **不含密鑰**。密碼、cookie、歷史紀錄一律不備份——那些透過你的 Mozilla 帳號（Zen）或 macOS Keychain（Claude）取回。

### Zen 目標
- **完全關閉 Zen → 自動備份**：打包 config-tier（prefs、workspaces/分頁、容器、Zen Mods、快捷鍵、擴充等），相同內容自動略過，留最新 **10** 份。
- **開啟 Zen → 提示還原**：雲端最新份不是本機這份時跳原生清單；可整包還原，或只**勾選特定工作區**併進現有 Zen。
- 每份 zip 內嵌 `restore.sh`，沒裝 Configgy 的機器也能解壓自還原。

### Claude Code 目標
- 快照 `~/.claude`（＋`~/.agents/skills`）的精華（`CLAUDE.md`、設定、`skills/`、`plugins/*.json`、`projects/*/memory/`），排除 session/快取/git clone。
- 每次備份是一份有日期的 zip（留 10、去重）→ **有歷史、可回滾**。還原為增量疊加，並重裝外掛 marketplaces/plugins。

### 自訂與自動發現目標
- **新增自訂備份資料夾…**：挑檔案/資料夾、命名，成為獨立的版本化目標（快照保留絕對路徑、還原放回原處）。
- **掃描建議的設定…**：自動找出本機**沒有自家雲端同步**的常見設定（shell dotfiles、git、`~/.ssh/config`、tmux、Vim/Neovim、Zed、VS Code、終端機、Karabiner、Hammerspoon、GitHub CLI，以及 MonitorControl/Moom/IINA 等選單列工具的偏好）。**預設不含密鑰**——SSH 私鑰與帶 token 的 `gh hosts.yml` 都排除。

### 還原前先預覽
還原 Zen（整包）、Claude 或自訂目標前，會先顯示**變更預覽**（哪些檔會被修改/新增）並請你確認；舊檔一律先備份，不會盲蓋。

## 安裝

1. 從 [Releases](https://github.com/rocavence/Configgy-app/releases) 下載 `.dmg`，把 **Configgy** 拖進「應用程式」。
2. 這是自簽的個人工具，Gatekeeper 會擋——第一次請**右鍵 App → 打開**。
3. **授予完整磁碟取用權**（系統設定 → 隱私權與安全性），它才碰得到 Dropbox 資料夾；首次啟動會引導你。
4. 沒有 Dropbox？啟動時會請你**指定一個備份資料夾**，之後都備到那裡。

App 本身就是背景監看器（每 2.5 秒輪詢），不需要 LaunchAgent。可在選單開啟「開機自動啟動」（預設關閉）。語言可在選單的「語言」切換（預設跟隨系統）。

## 從原始碼建置

需要 Xcode Command Line Tools（`swift`、`codesign`），不需完整 Xcode。

```sh
sh Scripts/build-app.sh           # → build/Configgy.app
cp -R build/Configgy.app /Applications/
open /Applications/Configgy.app
```

建置會優先用穩定的自簽身分（`Configgy Self-Signed`，否則退而用任何 `Findly Self-Signed` 金鑰），讓完整磁碟取用權的授權能跨重建保留。

## 命令列（同一個執行檔）

```
Configgy backup [--force] | list | status
Configgy restore [<zip> [ws <uuid…>]] | workspaces <zip> | preview <zip>
Configgy claude-backup | claude-list | claude-restore [<zip>] | claude-preview <zip>
Configgy discover | targets | target-add <id> <name> <path…>
Configgy target-backup <id> | target-list <id> | target-restore <id> [<zip>] | target-preview <id> [<zip>]
```

`preview` / `claude-preview` / `target-preview` 是 dry-run，只列出還原會變更哪些檔、不實際動手。

---

<sub>授權 <a href="LICENSE">CC BY-NC-SA 4.0</a> · 個人工具，原樣提供、不負擔保 · 用 Claude Code 打造。</sub>
