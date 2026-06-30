# Configgy

A macOS **menubar app** that backs up & restores your local config across
devices. Native Swift (AppKit, `LSUIElement`), no dependencies. Built like Findly.
Two targets, two mechanisms — both write under `~/…/Dropbox/Apps/Configgy/`.

## Zen target (`Apps/Configgy/zen/`) — versioned zip snapshots
- **Zen fully quits → auto-backup.** Snapshots the *config-tier* profile into
  `configgy-zen-<host>-<ts>.zip`. Identical states are skipped (deduped by
  content hash). Keeps the newest **10**. Each zip embeds a `restore.sh` so a
  bare machine without Configgy can self-restore (supersedes zen-settings-backup).
- **Zen opens → offer restore.** If the newest cloud backup isn't the one this
  Mac currently has, a native picker lists every backup (time · host ·
  workspaces/tabs). Pick one → Configgy **quits Zen, swaps the files in,
  relaunches Zen**. Restore can target **specific workspace(s)** (native checkbox
  window) — merges them into the current Zen, keeping the rest. Skip = no nag.
- Config tier: `prefs.js`, `user.js`, sessions/workspaces/tabs, containers, Zen
  Mods (`zen-themes.json` + `chrome/`), keyboard shortcuts, extensions (`.xpi` +
  `browser-extension-data`), search, handlers, xulstore, session backups.
  **Includes Enjoy. No secrets** — passwords/cookies/history return via the
  Mozilla account.

## Claude target (`Apps/Configgy/claude/`) — rsync mirror (manual)
- Swift port of the `claude-config-sync` skill. Mirrors the valuable bits of
  `~/.claude` (+ `~/.agents/skills`) — `CLAUDE.md`, settings, `skills/`,
  `plugins/*.json`, and `projects/*/memory/` — excluding sessions, caches, git
  clones. Restore is additive (no `--delete`) and reinstalls marketplaces /
  plugins / `brew install quarkdown`. **Manual only** (menu buttons).
  Credentials live in the Keychain — not backed up; re-login after a migration.

The app **is** the background watcher (polls every 2.5 s) — no LaunchAgent.
On first launch it migrates any legacy `Apps/zennly/*.zip` into `Apps/Configgy/zen/`.

Menu: Zen status · 備份 Zen · 還原 Zen…（可選工作區）· 備份 Claude 設定 ·
還原 Claude 設定 · 暫停 Zen 自動 · 開啟備份資料夾 · 結束.

## Build & install
```sh
sh Scripts/build-app.sh          # → build/Configgy.app
cp -R build/Configgy.app /Applications/
open /Applications/Configgy.app
```
Then **grant Full Disk Access** to `Configgy.app` (System Settings → Privacy &
Security → Full Disk Access) — without it Configgy can't read/write the Dropbox
folder. The build signs with a stable self-signed identity (`Configgy`/`Findly
Self-Signed`) so that grant survives rebuilds.

## CLI (same binary)
`Configgy backup [--force] | list | status | restore [zip [ws <uuid…>]] |
workspaces <zip> | claude-backup | claude-restore` — runs headless.
`CONFIGGY_TEST=1` treats Zen as closed and skips plugin reinstall (used by tests).

## Notes
- Each Zen zip is the full config tier incl. extensions (~tens of MB); 10 kept ⇒
  a few hundred MB. Lower `keep` in `Engine.swift` to trim.
- Accepting a Zen restore makes Zen **restart once**.
- "Newest" is ranked by the timestamp in the filename, across all devices.
- `legacy-node/` is the original Node prototype, kept for reference only.
