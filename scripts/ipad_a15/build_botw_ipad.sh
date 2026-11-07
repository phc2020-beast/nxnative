#!/bin/bash
# Breath of the Wild for an iPad mini 6 (A15) on Pablo's Intel Mac (Xcode 26.3).
# Keeps the iPhone build untouched: its own checkout, its own build folder, its own IPA name.
# Usage: build_botw_ipad.sh [NSP folder] [prod.keys]
set -euo pipefail
GAME=${1:-$HOME/Downloads/BotW}
KEYS=${2:-$HOME/Downloads/prod.keys}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PY=${PYTHON:-$HOME/.local/nxpython/python/bin/python3}
[ -x "$PY" ] || PY=python3
[ -f "$KEYS" ] || { echo "no prod.keys at $KEYS" >&2; exit 1; }
ls "$GAME"/*.nsp "$GAME"/*.xci "$GAME"/*.nsz 2>/dev/null | grep -q . || { echo "no NSP / XCI files in $GAME" >&2; exit 1; }
[ -d "$HOME/.dotnet" ] && export DOTNET_ROOT=${DOTNET_ROOT:-$HOME/.dotnet} PATH=$HOME/.dotnet:$PATH
export PATH=/usr/local/bin:$PATH
"$PY" -c 'import sys; assert sys.version_info >= (3, 12), sys.version' || { echo "$PY is older than Python 3.12" >&2; exit 1; }
"$PY" -m pip install -q lz4 "capstone>=5,<6" fonttools nsz "backports.zstd; python_version < '3.14'"
echo "Python $("$PY" -V), $(xcodebuild -version | head -1), metal $(xcrun -sdk iphoneos metal --version 2>&1 | head -1)"
df -h "$GAME" | tail -1
exec "$PY" "$REPO/scripts/build_ipa_from_nsp.py" "$GAME" -k "$KEYS" \
  --allow-other-metal --gpu none --romfs separate --keep-extracted \
  --env-file "$REPO/scripts/ipad_a15/botw-env.txt" \
  --bundle-id com.michellecarrega.botw \
  --work-dir "$GAME/ipad_a15_build" \
  -o "$GAME/ZeldaBreathOfTheWild-iPad.ipa" \
  --progress lines
