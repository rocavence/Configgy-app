#!/bin/bash
# Build Zennly as a macOS .app bundle → build/Zennly.app
# Requires Xcode Command Line Tools (swift, codesign).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Configgy"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

echo "→ swift build (release)"
swift build -c release

echo "→ assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS}/Info.plist"
[[ -f "Resources/AppIcon.icns" ]] && cp "Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Stable self-signed identity keeps the Full Disk Access grant across rebuilds
# (ad-hoc signatures change every build → TCC silently drops the grant).
# Prefer a Configgy cert; fall back to the existing Findly self-signed key so
# you don't have to make a new cert just for the rename (a self-signed cert is
# just a signing key — reusing it keeps the FDA grant stable across rebuilds).
SIGN_IDENTITY="Configgy Self-Signed"
for cand in "Configgy Self-Signed" "Findly Self-Signed"; do
  if security find-identity -p codesigning 2>/dev/null | grep -q "${cand}"; then SIGN_IDENTITY="${cand}"; break; fi
done
if security find-identity -p codesigning 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
  echo "→ codesign with ${SIGN_IDENTITY}"
  codesign --force --deep --sign "${SIGN_IDENTITY}" --timestamp=none "${APP_DIR}"
else
  echo "→ ad-hoc codesign（建議建一個穩定自簽身分，否則每次重建後要重設 Full Disk Access）"
  echo "   建法：鑰匙圈存取 → 憑證輔助程式 → 建立憑證 → 名稱「${SIGN_IDENTITY}」、類型 程式碼簽署、自我簽署；建完重跑本腳本即會自動採用。"
  codesign --force --deep --sign - "${APP_DIR}"
fi

echo
echo "Done →  open ${APP_DIR}    或安裝：cp -R ${APP_DIR} /Applications/"
