#!/bin/zsh
# swift test を実行する。Command Line Tools だけの環境では Swift Testing の
# マクロプラグインが自動で見つからないため、プラグインの場所を明示する。
set -euo pipefail

cd "$(dirname "$0")/.."

PLUGIN_DIR="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "${PLUGIN_DIR}" ]]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "${PLUGIN_DIR}" "$@"
else
    exec swift test "$@"
fi
