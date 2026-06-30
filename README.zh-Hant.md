<p align="center">
  <img src="Resources/icon-256.png" width="128" alt="Configgy icon">
</p>

<h1 align="center">Configgy</h1>

<p align="center">
  一款 macOS app，跨裝置備份與還原你的本機設定——
  <b>Zen Browser</b>、<b>Claude Code</b>，以及任何你指定的資料夾。
</p>

<p align="center">
  原生 Swift（AppKit）· 系統列常駐 + 單一管理視窗 · 零相依套件 ·
  備份落在 <code>Dropbox / iCloud / Google&nbsp;雲端硬碟 / 自選資料夾</code> 下的 <code>…/Configgy/</code>
</p>

<p align="center"><a href="README.md">English</a> · <b>繁體中文</b></p>

---

## 它在做什麼

Configgy 專門顧好那些「弄丟很痛、又不想丟進全資料夾雲端同步」的*設定檔*——版本化、可攜、一鍵即備份還原。它常駐於系統列，所有操作都集中在同一個視窗。

| 目標 | 機制 | 觸發 |
|---|---|---|
| **Zen Browser** | 版本化 `.zip` 快照（留 10 份、去重）；每個 zip 內嵌 `restore.sh` 可裸機自還原 | Zen 關閉時自動 |
| **Claude Code** | `~/.claude`（＋`~/.agents/skills`）的版本化 `.zip` 快照；還原時重裝 plugins | 手動 |
| **自訂／探索到的目標** | 保留絕對路徑的版本化 `.zip` 快照 | 手動 |

> **不碰機密。** 密碼、cookie、瀏覽紀錄、SSH 私鑰、含 token 的 `gh hosts.yml` 一律不複製——那些靠你的 Mozilla 帳號／鑰匙圈回來。

### 視窗

單一視窗，用膠囊 tab 切換兩份清單：

- **已備份保護** — 你正在保護的目標（Claude、已啟用的 Zen、自訂）。每列：app 圖示、名稱、*最後備份 · N 份*，以及 **備份／還原／移除** 三顆精巧 pill 按鈕（hover 才上色：綠／橘／紅）。
- **建議加入** — Zen，以及這台 Mac 上探索到、本身沒有雲端同步的設定（shell dotfiles、git、`~/.ssh/config`、Zed、VS Code、各家終端機、Karabiner、Hammerspoon、gh，以及 MonitorControl／Moom／IINA 等工具列 App）。點 **加入** 就開始版本化。

**齒輪 → 設定**頁（視窗內切換、右上 ✕ 關閉）含：**主題**（跟隨系統／淺色／深色）、**放大介面**（1.1×）、**開機自動啟動**、**備份位置**、**關於**。系統列選單只留 *打開 Configgy*、*關於*、*結束*（需要時多一個 FDA 提醒）。

### 細節質感

- **活的手感** — hover 高亮整列；備份時跑一條綠色流光進度條、完成後按鈕閃「✓ 備份完成」；還原是橘色；移除目標時該列粉碎。淺色／深色都是一等公民（淺色採 Finder 風配色）。
- **還原前先預覽** — 還原會先列出哪些檔案會變動並確認；覆寫前先把舊檔備份起來。
- **開啟自動納入** — 啟動時掃描備份資料夾，已備份過的目標（例如另一台 Mac 上）會重新出現、可直接還原。
- **Zen 很小心** — 備份 Zen 提供 *取消 · 關閉後自動備份 · 立即備份*，「立即備份」會再次確認才關閉你的瀏覽器。

## 安裝

1. 到 [Releases](https://github.com/rocavence/Configgy-app/releases) 下載 `.dmg`，把 **Configgy** 拖進 Applications。
2. 自簽個人工具 → Gatekeeper 會警告；第一次請 **右鍵 → 打開**。
3. **授予完全磁碟取用權（FDA）**（首次啟動會引導）才能讀寫備份資料夾。macOS 不會主動跳這個請求。
4. 選一個**備份位置**——預設 Dropbox；找不到時讓你選 Dropbox／iCloud 雲端硬碟／Google 雲端硬碟／自訂資料夾。

## 從原始碼建置

需要 Xcode 命令列工具（`swift`、`codesign`）；不需完整 Xcode。

```sh
sh Scripts/build-app.sh           # → build/Configgy.app
cp -R build/Configgy.app /Applications/
```

建置會用固定的自簽身分（`Configgy` / `Findly Self-Signed`）簽章，讓 FDA 在重建後仍有效。

## CLI

同一個執行檔可無介面執行：

```
Configgy backup [--force] | list | status | preview <zip>
Configgy restore [<zip> [ws <uuid…>]] | workspaces <zip>
Configgy claude-backup | claude-list | claude-restore [<zip>] | claude-preview <zip>
Configgy discover | targets | locations | target-add <id> <name> <path…>
Configgy target-backup <id> | target-list <id> | target-restore <id> [<zip>] | target-preview <id> [<zip>]
```

---

## 設計與開發脈絡

Configgy 的前身是 **Zennly**——一個只會一招的系統列小工具：Zen 關閉時把瀏覽器 profile 打包到 Dropbox，並提供跨裝置還原。後來一路長大：

- **從一個 app 變成一套模型。** 先加進 Claude Code 設定當第二個目標，接著把概念一般化：一個「目標」不過就是「一組路徑，以日期版本化成 zip，附歷史、差異預覽、附加式還原」。Zen 跟通用目標共用這個約定，Claude 只是多一步重裝 plugins。選 zip 快照而非單一 rsync 鏡像，是因為免費換來回滾能力，且檔名帶主機名避免跨機衝突。
- **預設安全。** 探索只建議「沒有自帶雲端同步」的設定，並刻意排除機密（SSH 金鑰、`gh` token）。還原會先預覽差異、並把要覆寫的舊檔先備起來。破壞性動作一律確認——而且 Zen 不會在沒有第二次點頭前關掉你的瀏覽器。
- **選擇加入，而非預設替你決定。** 開箱只有 Claude 是開的；Zen 跟其他都是「建議」，由你決定要不要納入。沒裝 Zen 的 Mac 也能正常啟動。
- **UI 反覆打磨。** 最後收斂成單一個 Mole 風視窗：一份清單、行內動作、設定做成視窗內頁面而非深層選單。視覺這關用上了 `ui-ux-pro` 與 `frontend-design` 兩個 skill——8pt 節奏、右對齊成群的動作、自繪 pill 按鈕（AppKit 原生 bezel 尺寸縮放不漂亮）、hover 才上的語意色、以及刻意弱化的破壞性動作。配色被一個真實的坑形塑：第一版用白色透明疊加，在淺色模式下整個隱形，所以現在顏色會隨外觀切換（深色提亮、淺色壓暗），並在外觀改變時重新解析。
- **沿路踩到的 macOS 眉角。** `NSStatusItem` 會忽略在選單動作裡重設選單（所以改在 `menuNeedsUpdate` 重建）；視窗的關閉*動畫*若在 transaction 中途被釋放會崩潰（所以放大重建改成延後＋`orderOut`）；FDA 從不主動跳請求（所以做了引導式 onboarding）；overlay 捲軸會切到列的圓角（所以列右側預留 gutter）。
- **幾乎全程用對話打造**——透過 Claude Code（Opus），每次改動都在「編譯→安裝→commit」的緊密迴圈裡完成；UI 則靠截圖一輪輪微調。

<sub>採 <a href="LICENSE">CC BY-NC-SA 4.0</a> 授權 · 個人工具，照原樣分享、不附保固 · 以 Claude Code 打造。</sub>
