<p align="center">
  <img src="Resources/icon-256.png" width="128" alt="Configgy icon">
</p>

<h1 align="center">Configgy</h1>

<p align="center">
  A tiny macOS <b>menubar app</b> that backs up &amp; restores your local config
  across devices — currently <b>Zen Browser</b> and <b>Claude Code</b>.
</p>

<p align="center">
  Native Swift (AppKit, <code>LSUIElement</code>) · no dependencies · backups land in
  <code>Dropbox/Apps/Configgy/</code>
</p>

---

## What it does

Configgy quietly lives in your menubar and keeps the *settings* that are painful
to lose — but which you don't want in a cloud sync — versioned and portable.
Two targets, two mechanisms:

| Target | Where | How | Trigger |
|---|---|---|---|
| **Zen Browser** | `Apps/Configgy/zen/` | versioned `.zip` snapshots (keeps 10, content-deduped) | **auto** on Zen quit |
| **Claude Code** | `Apps/Configgy/claude/` | versioned `.zip` snapshots (keeps 10, content-deduped) | **manual** (menu) |

> **No secrets.** Passwords, cookies and history are never copied — those come
> back through your Mozilla account (Zen) or macOS Keychain (Claude).

### Zen target — versioned snapshots
- **Zen fully quits → auto-backup.** Snapshots the *config-tier* profile:
  `prefs.js`, `user.js`, sessions / workspaces / tabs, containers, Zen Mods
  (`zen-themes.json` + `chrome/`), keyboard shortcuts, extensions (`.xpi` +
  `browser-extension-data`), search, handlers, xulstore, session backups.
  Identical states are skipped (hashed). Keeps the newest **10**.
- **Zen opens → offer restore.** If the newest cloud backup isn't the one this
  Mac currently has, a native picker lists every backup (time · host ·
  workspaces/tabs). Pick one → Configgy **quits Zen, swaps the files in,
  relaunches Zen.** You can restore **specific workspace(s)** only (checkbox
  window) and merge them into the current Zen, keeping the rest.
- Every zip embeds a `restore.sh`, so a machine without Configgy can still
  self-restore by unzipping and running it.

### Claude Code target — versioned snapshots
- Snapshots the valuable bits of `~/.claude` (+ `~/.agents/skills`): `CLAUDE.md`,
  settings, `skills/`, `plugins/*.json`, and `projects/*/memory/` — excluding
  sessions, caches and git clones. Each backup is a dated zip (keeps the newest
  **10**, identical states deduped), so you have **history & rollback** — pick any
  past snapshot to restore.
- Restore is **additive** (no deletes) and reinstalls plugin marketplaces,
  plugins, and `quarkdown` so symlink/plugin skills come back to life.

### Preview before restore
Restoring a Zen backup (full) or a Claude snapshot first shows a **change preview**
— which files would be modified or added — and asks to confirm. Old files are
backed up before being overwritten, so a restore is never a blind clobber.

## Install

1. Build the app (see below) and drop it in `/Applications`.
2. Launch it — a menubar icon appears.
3. **Grant Full Disk Access.** macOS never prompts for this automatically, so on
   first launch Configgy shows a short welcome that opens the right settings pane
   and highlights the app in Finder. Add `Configgy.app` to **System Settings →
   Privacy &amp; Security → Full Disk Access**, enable it, and choose *Quit &amp;
   Reopen*. Without it Configgy can't read or write the Dropbox folder.

The app **is** the background watcher (polls every 2.5 s) — there's no LaunchAgent.

## Build from source

Requires Xcode Command Line Tools (`swift`, `codesign`); no full Xcode needed.

```sh
swift Scripts/make-icon.swift     # regenerate the icon (optional)
sh Scripts/make-icon.sh           # → Resources/AppIcon.icns (optional)
sh Scripts/build-app.sh           # → build/Configgy.app
cp -R build/Configgy.app /Applications/
open /Applications/Configgy.app
```

The build prefers a stable self-signed identity (`Configgy Self-Signed`, falling
back to any `Findly Self-Signed` key) so the Full Disk Access grant survives
rebuilds — ad-hoc signatures change every build and silently drop the grant. Make
one in *Keychain Access → Certificate Assistant → Create a Certificate* (Code
Signing, self-signed) if you don't have one.

## CLI

The same binary runs headless:

```
Configgy backup [--force] | list | status
Configgy restore [<zip> [ws <uuid…>]] | workspaces <zip> | preview <zip>
Configgy claude-backup | claude-list | claude-restore [<zip>] | claude-preview <zip>
```

`preview` / `claude-preview` are dry-runs — they print which files a restore would
change, without touching anything.

`CONFIGGY_TEST=1` treats Zen as closed and skips plugin reinstall (used by tests).

## Notes

- Each Zen zip is the full config tier incl. extensions (~tens of MB); 10 kept ⇒
  a few hundred MB in Dropbox. Lower `keep` in `Engine.swift` to trim.
- Accepting a Zen restore makes Zen **restart once** (it already read its session
  on open; relaunching is the only way to reload it).
- "Newest" is ranked by the timestamp in the filename, across all devices.
- `legacy-node/` is the original Node prototype, kept for reference only.

---

<sub>Licensed under <a href="LICENSE">CC BY-NC-SA 4.0</a> · a personal tool, shared as-is — no warranty · built with Claude Code.</sub>
