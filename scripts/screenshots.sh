#!/bin/zsh
# 官網與 README 用的 App 截圖：在假的家目錄裡放一組像真的資料，讓 App 真的打開
# 每個視窗，再用 screencapture 連同視窗外框與陰影拍下來（需要終端機有「螢幕錄製」權限）。
# 用法：scripts/screenshots.sh [語言，預設 zh-Hant]   輸出：build/screenshots/*.png
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/screenshots
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate --quiet
xcodebuild -project Configgy.xcodeproj -scheme Configgy -configuration Debug \
  -derivedDataPath build/xcode.noindex build | grep -E "error:|BUILD FAILED" || true
APP=build/xcode.noindex/Build/Products/Debug/Configgy.app/Contents/MacOS/Configgy

CONFIGGY_HOME="$PWD/build/screenshots-home" CONFIGGY_SHOTS="$PWD/$OUT" CONFIGGY_SELFTEST=screenshots \
  "$APP" -AppleLanguages "(\"${1:-zh-Hant}\")" > "$OUT/log" 2>&1 &
PID=$!
for _ in {1..600}; do
  for req in "$OUT"/*.request(N); do
    name=$(basename "$req" .request)
    screencapture -x -l "$(cat "$req")" "$OUT/$name.full.png"
    sips -Z 1600 "$OUT/$name.full.png" --out "$OUT/$name.png" >/dev/null
    rm -f "$req" "$OUT/$name.full.png"
    echo "拍好：$name"
  done
  kill -0 $PID 2>/dev/null || break
  sleep 0.1
done
kill $PID 2>/dev/null || true
grep -E "SCREENSHOTS|no capture" "$OUT/log"
