# Zennly

A macOS **menubar app** that auto-backs-up Zen Browser and restores across devices.
Native Swift (AppKit, `LSUIElement`), no dependencies. Built like Findly.

## What it does
- **Zen fully quits → auto-backup.** Snapshots the *config-tier* profile into
  `~/…/Dropbox/Apps/zennly/zennly-<host>-<ts>.zip`. Identical states are skipped
  (deduped by content hash). Keeps the newest **10**.
- **Zen opens → offer restore.** If the newest cloud backup isn't the one this
  Mac currently has, a native picker lists every backup (time · host ·
  workspaces/tabs). Pick one → Zennly **quits Zen, swaps the files in, relaunches
  Zen**. Skip = no nag for that same backup.
- Menubar menu: status · 立即備份 · 還原備份… · 暫停 · 開啟 Dropbox 資料夾 · 結束.

The app **is** the background watcher (polls every 2.5 s) — no LaunchAgent.

## Config tier (in each zip)
`prefs.js`, `user.js`, sessions/workspaces/tabs, containers, Zen Mods
(`zen-themes.json` + `chrome/`), keyboard shortcuts, extensions (`.xpi`), search,
handlers, xulstore, session backups. **Includes Enjoy.** **No secrets** —
passwords/cookies/history come back via the Mozilla account.

## Build & install
```sh
sh Scripts/build-app.sh          # → build/Zennly.app
cp -R build/Zennly.app /Applications/
open /Applications/Zennly.app
```
Then **grant Full Disk Access** to `Zennly.app` (System Settings → Privacy &
Security → Full Disk Access). Without it Zennly can't read/write the Dropbox
folder. (Tip: create a stable self-signed identity "Zennly Self-Signed" in
Keychain Access so the FDA grant survives rebuilds — see `build-app.sh`.)

## CLI (same binary)
`Zennly backup [--force] | list | status | restore [zip]` — runs headless.
`ZENNLY_TEST=1` treats Zen as closed and never launches it (used by tests).

## Notes
- Each zip is the full config tier incl. extensions (~tens of MB); 10 kept ⇒ a
  few hundred MB in Dropbox. Lower `keep` in `Engine.swift` to trim.
- Accepting a restore makes Zen **restart once** (it already read its session on
  open; the only way to reload it).
- "Newest" is ranked by the timestamp in the filename, across all devices.
- `legacy-node/` is the original Node prototype, kept for reference only.
