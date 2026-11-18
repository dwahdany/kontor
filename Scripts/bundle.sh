#!/bin/bash
# Builds Kontor and assembles dist/Kontor.app.
#
#   Scripts/bundle.sh [debug|release] [--sandbox|--no-sandbox] [--no-verify]
#
# debug   (default) hardened runtime, NOT sandboxed — so the headless screenshot mode can read and
#         write arbitrary paths (`Kontor --screenshot … --out /any/where.png`).
# release hardened runtime + App Sandbox (user-selected files read/write, outgoing network).
# --sandbox / --no-sandbox override the default of the configuration.
# --no-verify skips the launch check at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="debug"
SANDBOX=""
VERIFY=1
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --sandbox) SANDBOX=1 ;;
        --no-sandbox) SANDBOX=0 ;;
        --no-verify) VERIFY=0 ;;
        *) echo "usage: Scripts/bundle.sh [debug|release] [--sandbox|--no-sandbox] [--no-verify]" >&2; exit 64 ;;
    esac
done
if [[ -z "$SANDBOX" ]]; then
    if [[ "$CONFIG" == "release" ]]; then SANDBOX=1; else SANDBOX=0; fi
fi

VERSION="${KONTOR_VERSION:-0.1.0}"
BUILD="${KONTOR_BUILD:-$(date +%Y%m%d%H%M)}"
APP="$ROOT/dist/Kontor.app"

echo "▸ Building Kontor ($CONFIG)"
swift build -c "$CONFIG" --product Kontor
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling $APP"
# Quit a running copy first: replacing the bundle under a live process confuses LaunchServices.
pkill -x Kontor 2>/dev/null && sleep 0.5 || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Kontor" "$APP/Contents/MacOS/Kontor"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# App icon: rendered by Scripts/make-icon.swift, cached until that script changes.
ICON_CACHE="$ROOT/.build/icon"
ICON_STAMP="$ICON_CACHE/$(shasum "$ROOT/Scripts/make-icon.swift" | cut -c1-16).icns"
if [[ ! -f "$ICON_STAMP" ]]; then
    echo "▸ Rendering app icon"
    rm -rf "$ICON_CACHE"
    mkdir -p "$ICON_CACHE"
    swift "$ROOT/Scripts/make-icon.swift" "$ICON_CACHE/AppIcon.iconset"
    iconutil --convert icns --output "$ICON_STAMP" "$ICON_CACHE/AppIcon.iconset"
fi
cp "$ICON_STAMP" "$APP/Contents/Resources/AppIcon.icns"

if [[ "$SANDBOX" == 1 ]]; then
    ENTITLEMENTS="$ROOT/Resources/Kontor.entitlements"
    echo "▸ Signing (ad hoc, hardened runtime, App Sandbox)"
else
    ENTITLEMENTS="$ROOT/Resources/Kontor-dev.entitlements"
    echo "▸ Signing (ad hoc, hardened runtime, no sandbox — development)"
fi
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [[ "$VERIFY" == 1 ]]; then
    echo "▸ Verifying launch"
    open -n -g "$APP"
    alive=0
    for _ in $(seq 1 20); do
        sleep 0.25
        if pgrep -x Kontor > /dev/null; then alive=1; break; fi
    done
    sleep 2
    if [[ "$alive" == 1 ]] && pgrep -x Kontor > /dev/null; then
        echo "  launched and stayed alive (pid $(pgrep -x Kontor | head -1))"
        osascript -e 'tell application id "app.kontor.Kontor" to quit' > /dev/null 2>&1 || pkill -x Kontor || true
        for _ in $(seq 1 20); do
            pgrep -x Kontor > /dev/null || break
            sleep 0.25
        done
        pkill -x Kontor 2>/dev/null || true
    else
        echo "error: Kontor.app did not stay alive after launch" >&2
        exit 1
    fi
fi

echo "✔ $APP ($CONFIG, $([[ "$SANDBOX" == 1 ]] && echo sandboxed || echo unsandboxed), version $VERSION)"
