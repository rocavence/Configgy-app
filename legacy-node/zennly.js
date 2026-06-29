#!/usr/bin/env node
'use strict';
/*
 * Zennly — automatic Zen Browser settings backup + cross-device restore.
 *
 * • Every time Zen FULLY QUITS, snapshot the config-tier profile into a zip and
 *   drop it in Dropbox/Apps/zennly/  (zennly-<host>-<ts>.zip).
 * • Every time Zen OPENS, if the newest cloud backup isn't the one this machine
 *   currently has, pop a native picker — you choose which backup to restore.
 *   Restoring quits Zen, swaps the files in, and relaunches Zen.
 *
 * Config tier = settings + Zen Mods + extensions + workspaces/tabs (incl. the
 * Enjoy workspace). NO secrets (passwords/cookies/history) — those live in the
 * Mozilla account, not in the profile files we copy.
 *
 * Commands: watch | backup | list | restore [zip] | status
 *
 * NOTE: writing the Dropbox folder requires Full Disk Access for the node binary
 * (System Settings → Privacy & Security → Full Disk Access). setup.sh explains.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execSync, execFileSync } = require('child_process');

const HOME = os.homedir();
const ZEN_ROOT = path.join(HOME, 'Library', 'Application Support', 'zen');
const HOST = os.hostname().replace(/\.local$/, '').replace(/[^A-Za-z0-9_-]/g, '');
const STATE_DIR = path.join(HOME, 'Library', 'Application Support', 'zennly');
const STATE_FILE = path.join(STATE_DIR, 'state.json');
const POLL_MS = 2500;
const KEEP = 10;

// config-tier file set (copied only if present) — mirrors zen-settings-backup.
const FILES = ['prefs.js', 'user.js', 'zen-themes.json', 'zen-keyboard-shortcuts.json',
  'zen-boosts.jsonlz4', 'zen-sessions.jsonlz4', 'zen-space-routing.jsonlz4',
  'zen-live-folders.jsonlz4', 'containers.json', 'xulstore.json', 'search.json.mozlz4',
  'handlers.json', 'extensions.json', 'addonStartup.json.lz4', 'times.json',
  'sessionCheckpoints.json', 'compatibility.ini'];
const DIRS = ['chrome', 'extensions', 'zen-sessions-backup', 'sessionstore-backups'];

// ---------- detection ----------
function detectProfileDir() {
  const installs = path.join(ZEN_ROOT, 'installs.ini');
  if (fs.existsSync(installs)) {
    const m = fs.readFileSync(installs, 'utf8').match(/^Default=(.+)$/m);
    if (m) return path.join(ZEN_ROOT, m[1].trim());
  }
  const profiles = path.join(ZEN_ROOT, 'profiles.ini');
  if (fs.existsSync(profiles)) {
    for (const b of fs.readFileSync(profiles, 'utf8').split(/\n(?=\[)/)) {
      if (/Default=1/.test(b)) {
        const p = b.match(/^Path=(.+)$/m);
        if (p) return /IsRelative=1/.test(b) ? path.join(ZEN_ROOT, p[1].trim()) : p[1].trim();
      }
    }
  }
  throw new Error('Could not detect Zen profile directory');
}
function detectDropbox() {
  for (const base of [path.join(HOME, 'Dropbox'), path.join(HOME, 'Library', 'CloudStorage', 'Dropbox')]) {
    if (fs.existsSync(base)) return path.join(base, 'Apps', 'zennly');
  }
  return path.join(HOME, 'Library', 'CloudStorage', 'Dropbox', 'Apps', 'zennly');
}
const PROFILE_DIR = detectProfileDir();
const DROPBOX_DIR = detectDropbox();

function zenRunning() {
  if (process.env.ZENNLY_TEST) return false;   // test seam: never touch the real running Zen
  try { execSync('pgrep -f "Zen.app/Contents/MacOS/zen" >/dev/null 2>&1'); return true; }
  catch { return false; }
}

// ---------- mozLz4 decode (for the session summary shown in the picker) ----------
function lz4dec(src, destLen) {
  const dst = Buffer.alloc(destLen); let s = 0, d = 0;
  while (s < src.length) {
    const tok = src[s++]; let lit = tok >> 4;
    if (lit === 15) { let b; do { b = src[s++]; lit += b; } while (b === 255); }
    src.copy(dst, d, s, s + lit); s += lit; d += lit;
    if (s >= src.length) break;
    const off = src[s] | (src[s + 1] << 8); s += 2;
    let m = tok & 15; if (m === 15) { let b; do { b = src[s++]; m += b; } while (b === 255); }
    m += 4; let mp = d - off;
    for (let i = 0; i < m; i++) dst[d++] = dst[mp++];
  }
  return dst.slice(0, d);
}
function summarizeSessions(buf) {
  try {
    if (buf.slice(0, 8).toString('latin1') !== 'mozLz40\0') return null;
    const j = JSON.parse(lz4dec(buf.slice(12), buf.readUInt32LE(8)).toString('utf8'));
    const tabs = j.tabs || [];
    return {
      workspaces: (j.spaces || []).map(s => `${s.icon || ''} ${s.name}`.trim()),
      tabs: tabs.length, pinned: tabs.filter(t => t.pinned).length,
      essentials: tabs.filter(t => t.zenEssential).length,
    };
  } catch { return null; }
}

// ---------- hashing the live profile (dedup identical quits) ----------
function profileHash() {
  const h = crypto.createHash('sha1');
  const add = fp => { try { h.update(fp); h.update(fs.readFileSync(fp)); } catch {} };
  for (const f of FILES) { const fp = path.join(PROFILE_DIR, f); if (fs.existsSync(fp)) add(fp); }
  for (const d of DIRS) {
    const root = path.join(PROFILE_DIR, d);
    if (!fs.existsSync(root)) continue;
    (function rec(dir, rel) {
      for (const name of fs.readdirSync(dir).sort()) {
        const fp = path.join(dir, name), r = `${rel}/${name}`;
        if (fs.statSync(fp).isDirectory()) rec(fp, r); else add(r), add(fp);
      }
    })(root, d);
  }
  return h.digest('hex');
}

// ---------- state ----------
function readState() { try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch { return {}; } }
function writeState(s) { fs.mkdirSync(STATE_DIR, { recursive: true }); fs.writeFileSync(STATE_FILE, JSON.stringify(s, null, 2)); }

// ---------- cloud listing ----------
function listZips() {
  if (!fs.existsSync(DROPBOX_DIR)) return [];
  return fs.readdirSync(DROPBOX_DIR).filter(f => /^zennly-.+\.zip$/.test(f)).sort(); // ts in name → lexicographic = chronological
}
function newestZip() { const z = listZips(); return z.length ? z[z.length - 1] : null; }
function zipMeta(zip) {                         // read embedded meta.json without full unzip
  try { return JSON.parse(execFileSync('unzip', ['-p', path.join(DROPBOX_DIR, zip), 'snapshot/meta.json'], { maxBuffer: 1 << 20 }).toString()); }
  catch { return null; }
}

// ---------- timestamp (passed where needed; avoids Date in hot equality paths) ----------
function stamp() {
  const d = new Date(), p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

// ---------- backup ----------
function doBackup({ force = false } = {}) {
  if (zenRunning()) { log('Zen 還開著，略過備份（關閉時才會打包）。'); return null; }
  const hash = profileHash();
  const st = readState();
  if (!force && st.lastBackupHash === hash) { log('設定沒變，略過重複備份。'); return null; }

  fs.mkdirSync(DROPBOX_DIR, { recursive: true });
  const ts = stamp();
  const name = `zennly-${HOST}-${ts}.zip`;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'zennly-'));
  const stage = path.join(tmp, 'snapshot');
  fs.mkdirSync(path.join(stage, 'profile'), { recursive: true });
  for (const f of FILES) { const s = path.join(PROFILE_DIR, f); if (fs.existsSync(s)) execFileSync('cp', ['-p', s, path.join(stage, 'profile', f)]); }
  for (const d of DIRS) { const s = path.join(PROFILE_DIR, d); if (fs.existsSync(s)) execFileSync('cp', ['-Rp', s, path.join(stage, 'profile', d)]); }

  let summary = null;
  const sess = path.join(stage, 'profile', 'zen-sessions.jsonlz4');
  if (fs.existsSync(sess)) summary = summarizeSessions(fs.readFileSync(sess));
  const meta = { host: HOST, ts, iso: new Date().toISOString(), profileHash: hash, summary };
  fs.writeFileSync(path.join(stage, 'meta.json'), JSON.stringify(meta, null, 2));
  fs.copyFileSync(__filename, path.join(stage, 'zennly.js'));   // self-contained restore on any machine

  const out = path.join(DROPBOX_DIR, name);
  execFileSync('zip', ['-rqy', out, 'snapshot'], { cwd: tmp });
  fs.rmSync(tmp, { recursive: true, force: true });

  // prune: keep newest KEEP
  const all = listZips();
  for (const old of all.slice(0, Math.max(0, all.length - KEEP))) { try { fs.unlinkSync(path.join(DROPBOX_DIR, old)); } catch {} }

  st.lastBackupHash = hash; st.currentZip = name; st.dismissedZip = null;
  writeState(st);
  log(`✓ 已備份 → ${name}` + (summary ? `  [${summary.workspaces.join(' · ')} / ${summary.tabs} 分頁]` : ''));
  return name;
}

// ---------- restore ----------
function restoreZip(zip) {
  const zpath = path.join(DROPBOX_DIR, zip);
  if (!fs.existsSync(zpath)) { fail(`找不到備份：${zip}`); return; }
  const lock = path.join(STATE_DIR, 'restoring.lock');
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(lock, zip);
  try {
    if (zenRunning()) { log('關閉 Zen…'); try { execFileSync('osascript', ['-e', 'tell application "Zen" to quit']); } catch {}
      for (let i = 0; i < 40 && zenRunning(); i++) execSync('sleep 0.5'); }

    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'zennly-r-'));
    execFileSync('unzip', ['-qo', zpath, '-d', tmp]);
    const src = path.join(tmp, 'snapshot', 'profile');
    if (!fs.existsSync(src)) { fail('備份內容損壞（找不到 profile/）'); return; }

    const bk = path.join(PROFILE_DIR, `pre-restore-backup-${stamp()}`);
    fs.mkdirSync(bk, { recursive: true });
    for (const name of fs.readdirSync(src)) {
      const dst = path.join(PROFILE_DIR, name);
      if (fs.existsSync(dst)) { execFileSync('cp', ['-Rp', dst, path.join(bk, name)]); fs.rmSync(dst, { recursive: true, force: true }); }
      execFileSync('cp', ['-Rp', path.join(src, name), PROFILE_DIR + path.sep]);
    }
    fs.rmSync(tmp, { recursive: true, force: true });

    const st = readState();
    st.currentZip = zip; st.lastBackupHash = profileHash(); st.dismissedZip = null;
    writeState(st);
    log(`✓ 已還原 ${zip}（舊設定備份在 ${path.basename(bk)}）`);
    if (!process.env.ZENNLY_TEST) { log('重新開啟 Zen…'); try { execFileSync('open', ['-a', 'Zen']); } catch {} }
  } finally { try { fs.unlinkSync(lock); } catch {} }
}

// ---------- picker (native macOS dialog) ----------
function metaLabel(zip) {
  const m = zipMeta(zip);
  const t = m && m.ts;                                  // local "YYYYMMDD-HHMMSS"
  const when = t ? `${t.slice(0, 4)}-${t.slice(4, 6)}-${t.slice(6, 8)} ${t.slice(9, 11)}:${t.slice(11, 13)}` : zip;
  const who = m && m.host ? m.host : '?';
  const s = m && m.summary;
  const tail = s ? `${s.workspaces.join(' · ')} · ${s.tabs}分頁/${s.essentials}essentials` : '';
  return `${when}  ·  ${who}  ·  ${tail}`;
}
function promptRestore() {
  const zips = listZips();
  if (!zips.length) return;
  // newest first for the picker
  const ordered = [...zips].reverse();
  const labels = ordered.map(metaLabel);
  const map = {}; ordered.forEach((z, i) => { map[labels[i]] = z; });
  const listLit = '{' + labels.map(l => '"' + l.replace(/"/g, '\\"') + '"').join(', ') + '}';
  const script = `choose from list ${listLit} with title "Zennly" with prompt "雲端有較新的 Zen 備份，要還原哪一份？（會關閉並重開 Zen）" OK button name "還原" cancel button name "略過" default items {item 1 of ${listLit}}`;
  let chosen;
  try { chosen = execFileSync('osascript', ['-e', script]).toString().trim(); }
  catch { chosen = 'false'; }
  if (!chosen || chosen === 'false') {                 // dismissed → don't nag for this same newest set
    const st = readState(); st.dismissedZip = newestZip(); writeState(st);
    log('使用者略過還原。');
    return;
  }
  const zip = map[chosen];
  if (zip) restoreZip(zip);
}

// ---------- watch loop ----------
function doWatch() {
  log(`watch 啟動（host ${HOST}）— 每 ${POLL_MS / 1000}s 偵測；Dropbox: ${DROPBOX_DIR}`);
  let wasRunning = zenRunning();
  const tick = () => {
    try {
      const now = zenRunning();
      if (now && !wasRunning) {                         // OPEN edge
        const newest = newestZip(), st = readState();
        if (newest && newest !== st.currentZip && newest !== st.dismissedZip) {
          execSync('sleep 2');                          // let Zen settle before we may quit it
          promptRestore();
        }
      } else if (!now && wasRunning) {                  // QUIT edge
        if (!fs.existsSync(path.join(STATE_DIR, 'restoring.lock'))) doBackup();
      }
      wasRunning = zenRunning();
    } catch (e) { log(`watch error: ${e.message}`); }
  };
  tick();
  setInterval(tick, POLL_MS);
}

// ---------- status / list ----------
function doStatus() {
  const st = readState();
  log(`Profile : ${PROFILE_DIR}`);
  log(`Dropbox : ${DROPBOX_DIR}`);
  log(`Host    : ${HOST}`);
  log(`Zen     : ${zenRunning() ? 'RUNNING' : 'closed'}`);
  log(`目前本機對應備份 : ${st.currentZip || '(無)'}`);
  log(`雲端最新備份     : ${newestZip() || '(無)'}`);
}
function doList() {
  const zips = [...listZips()].reverse();
  if (!zips.length) { log('雲端還沒有備份。'); return; }
  log(`雲端備份（新→舊，共 ${zips.length}）：`);
  for (const z of zips) console.log('  ' + z + '\n      ' + metaLabel(z));
}

// ---------- cli ----------
function log(m) { console.log(`[zennly] ${m}`); }
function fail(m) { console.error(`[zennly] ${m}`); process.exitCode = 1; }

const cmd = process.argv[2];
const arg = process.argv[3];
switch (cmd) {
  case 'watch': doWatch(); break;
  case 'backup': doBackup({ force: process.argv.includes('--force') }); break;
  case 'list': doList(); break;
  case 'restore': arg ? restoreZip(arg) : promptRestore(); break;
  case 'status': case undefined: doStatus(); break;
  default: console.log('Usage: zennly.js [watch|backup|list|restore [zip]|status]'); process.exitCode = 1;
}
