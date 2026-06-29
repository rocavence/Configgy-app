#!/bin/sh
# Zennly setup — install the background watcher LaunchAgent for this Mac.
# Run once per machine.  (Double-click setup.command, or: sh setup.sh)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/zennly.js"
[ -f "$TOOL" ] || { echo "✗ zennly.js not found next to setup.sh"; exit 1; }

NODE="$(command -v node || true)"
[ -n "$NODE" ] || { echo "✗ node not found on PATH — install Node first."; exit 1; }

LABEL="com.rocavence.zennly"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HERE/zennly.log"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$TOOL</string>
    <string>watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load  "$PLIST"
echo "✓ 已安裝並啟動背景監看：$PLIST"
echo "  node : $NODE"
echo "  log  : $LOG"
echo
echo "⚠️  最後一步（只能手動，macOS 規定）："
echo "    系統設定 → 隱私權與安全性 → 完全取得硬碟存取權（Full Disk Access）"
echo "    把這支 node 加進去並打開：$NODE"
echo "    （否則 Zennly 寫不進 Dropbox，會出現 Operation not permitted）"
echo "    加完後重跑一次：launchctl kickstart -k gui/\$(id -u)/$LABEL"
echo
echo "之後：關閉 Zen → 自動備份；開啟 Zen 且雲端有較新備份 → 跳出還原選單。"
