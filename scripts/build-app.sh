#!/bin/zsh
# SwiftPM でビルドし、Info.plist 付きの .app バンドルを build/ に作る。
# マイク・音声キャプチャの権限ダイアログは .app として起動したときだけ正しく出る。
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP_NAME="Otolemo"
APP_DIR="build/${APP_NAME}.app"

swift build -c "${CONFIGURATION}" --product "${APP_NAME}"
BIN_DIR="$(swift build -c "${CONFIGURATION}" --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# 権限 (TCC) をビルドごとに失わないよう、アドホック署名で識別子を固定する。
codesign --force --sign - --identifier "io.github.yuuulf.Otolemo" "${APP_DIR}"

echo "Built ${APP_DIR}"
echo "Run: open ${APP_DIR}"
