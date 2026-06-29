# Zennly

Automatic Zen Browser backup + cross-device restore, via a Dropbox folder.
No OAuth, no server, no extension — a small Node daemon driven by a LaunchAgent.

## What it does
- **Zen fully quits → auto-backup.** Snapshots the *config-tier* profile into
  `~/…/Dropbox/Apps/zennly/zennly-<host>-<ts>.zip`. Identical states are skipped
  (deduped by content hash). Keeps the newest **10**.
- **Zen opens → offer restore.** If the newest cloud backup isn't the one this
  machine currently has, a native picker lists every backup (time · host ·
  workspaces/tabs). Pick one → Zennly **quits Zen, swaps the files in, relaunches
  Zen**. Skip = no nag for that same backup.

## Config tier (what's in each zip)
`prefs.js`, `user.js`, sessions/workspaces/tabs (`zen-sessions.jsonlz4`),
containers, Zen Mods (`zen-themes.json` + `chrome/`), keyboard shortcuts,
extensions (`.xpi`), search, handlers, xulstore, session backups, etc.
**Includes the Enjoy workspace** (no exclusion). **No secrets** — passwords /
cookies / history come back by signing into the Mozilla account.

## Install (per machine)
1. Double-click **`setup.command`** (or `sh setup.sh`). Installs + starts the
   watcher LaunchAgent.
2. **Grant Full Disk Access to node** (macOS requires this by hand):
   System Settings → Privacy & Security → Full Disk Access → add the `node`
   path printed by setup. Without it Zennly can't write Dropbox
   (`Operation not permitted`).
3. Re-kick once: `launchctl kickstart -k gui/$(id -u)/com.rocavence.zennly`

## Manual use
- `backup.command` — back up now (close Zen first).
- `restore.command` — pop the picker now (quits/restores/relaunches Zen).
- CLI: `node zennly.js [watch|backup|list|restore [zip]|status]`

## Notes
- Each zip is the full config tier incl. extensions (~tens of MB); 10 kept ⇒ a
  few hundred MB in Dropbox. Lower `KEEP` in `zennly.js` to trim.
- Accepting a restore makes Zen visibly **restart once** (it already read its
  session on open; that's the only way to reload it).
- "Newest" is ordered by the timestamp in the filename — keep device clocks sane.
- `ZENNLY_TEST=1` is a test seam (treats Zen as closed, never launches it).
