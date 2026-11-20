#!/bin/zsh
# Resources/AppIcon のロゴ画像から Resources/AppIcon.icns を作る。
# ロゴを差し替えたときだけ実行し、できた AppIcon.icns をコミットする。
#
# 使い方: scripts/make-icon.sh [light|dark]（既定は light）
set -euo pipefail

cd "$(dirname "$0")/.."

VARIANT="${1:-light}"
SOURCE="Resources/AppIcon/logo-${VARIANT}.png"
[[ -f "${SOURCE}" ]] || { echo "not found: ${SOURCE}" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ICONSET="${WORK}/AppIcon.iconset"
mkdir -p "${ICONSET}"

swift scripts/make-icon.swift "${SOURCE}" "${WORK}/icon-1024.png"

for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${WORK}/icon-1024.png" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "${double}" "${double}" "${WORK}/icon-1024.png" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "${ICONSET}" --output Resources/AppIcon.icns
echo "Built Resources/AppIcon.icns from ${SOURCE}"
