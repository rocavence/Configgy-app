#!/bin/zsh
# 端對端自我測試：在假的家目錄與假的雲端資料夾裡實際備份、還原、開視窗，
# 不會碰你真正的設定、Zen 或 Dropbox。
# 用法：scripts/selftest.sh [項目]   紀錄在 build/selftest/log，截圖在 build/selftest/shots
# 項目：secrets retention location restore scope scan corrupt workspaces status windows（不填就全跑）
# 換語言或外觀：CONFIGGY_LANG=ja CONFIGGY_APPEARANCE=dark scripts/selftest.sh windows
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/selftest
rm -rf "$OUT" && mkdir -p "$OUT/shots"

xcodegen generate --quiet
xcodebuild -project Configgy.xcodeproj -scheme Configgy -configuration Debug \
  -derivedDataPath build/xcode.noindex build | grep -E "error:|BUILD FAILED" || true
APP=build/xcode.noindex/Build/Products/Debug/Configgy.app/Contents/MacOS/Configgy

APPEARANCE=()
[[ -n "${CONFIGGY_APPEARANCE:-}" ]] && APPEARANCE=(-Configgy.appearance "$CONFIGGY_APPEARANCE")
CONFIGGY_HOME="$PWD/$OUT/fixture" CONFIGGY_SHOTS="$PWD/$OUT/shots" CONFIGGY_SELFTEST="${1:-all}" \
  "$APP" -AppleLanguages "(\"${CONFIGGY_LANG:-zh-Hant}\")" "${APPEARANCE[@]}" > "$OUT/log" 2>&1 &
PID=$!
for _ in {1..90}; do
  sleep 1
  kill -0 $PID 2>/dev/null || break
done
kill $PID 2>/dev/null || true
grep -E "PASS|FAIL|SELFTEST" "$OUT/log"
grep -q "SELFTEST OK" "$OUT/log"
