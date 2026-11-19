#!/bin/bash
# Builds Kontor and assembles the app bundle.
#
#   Scripts/bundle.sh [debug|release] [--sandbox|--no-sandbox] [--verify] [--quiet]
#
# debug   (default) hardened runtime, NOT sandboxed — so the headless screenshot mode can read and
#         write arbitrary paths (`Kontor --screenshot … --out /any/where.png`).
# release hardened runtime + App Sandbox (user-selected files read/write, outgoing network).
# --sandbox / --no-sandbox override the default of the configuration.
# --verify additionally launches the bundle once — in the background and hidden (it never comes to
#         the front or shows a window on top of your work) — and checks that it stays alive.
#         Off by default; --no-verify is accepted for compatibility.
# --quiet prints only errors (and the build log if the build fails).
#
# Feature isolation: with KONTOR_FEATURES set (e.g. KONTOR_FEATURES=Holdings) only those features
# are compiled, into their own scratch directory and bundle, so parallel work never collides:
#
#   KONTOR_FEATURES unset / all   → .build/            dist/Kontor.app
#   KONTOR_FEATURES=Holdings      → .build-holdings/   dist-holdings/Kontor.app
#   KONTOR_FEATURES=Holdings,Plans→ .build-holdings-plans/  dist-holdings-plans/Kontor.app
#
# The script only ever touches (and quits) the copy of the app inside its own bundle directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="debug"
SANDBOX=""
VERIFY=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --sandbox) SANDBOX=1 ;;
        --no-sandbox) SANDBOX=0 ;;
        --no-verify) VERIFY=0 ;;
        --verify) VERIFY=1 ;;
        --quiet) QUIET=1 ;;
        *) echo "usage: Scripts/bundle.sh [debug|release] [--sandbox|--no-sandbox] [--verify] [--quiet]" >&2; exit 64 ;;
    esac
done
if [[ -z "$SANDBOX" ]]; then
    if [[ "$CONFIG" == "release" ]]; then SANDBOX=1; else SANDBOX=0; fi
fi
say() { if [[ "$QUIET" == 0 ]]; then echo "$@"; fi; }

# Scratch directory and bundle location follow the feature selection.
SELECTION="$(printf '%s' "${KONTOR_FEATURES-all}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
if [[ -z "${KONTOR_FEATURES+x}" || "$SELECTION" == "all" ]]; then
    unset KONTOR_FEATURES
    SCRATCH="$ROOT/.build"
    DIST="$ROOT/dist"
else
    SLUG="$(printf '%s' "${SELECTION:-none}" | tr ',' '-')"
    SCRATCH="$ROOT/.build-$SLUG"
    DIST="$ROOT/dist-$SLUG"
fi

VERSION="${KONTOR_VERSION:-0.1.0}"
BUILD="${KONTOR_BUILD:-$(date +%Y%m%d%H%M)}"
APP="$DIST/Kontor.app"
EXECUTABLE="$APP/Contents/MacOS/Kontor"

say "▸ Building Kontor ($CONFIG${KONTOR_FEATURES+, features: $KONTOR_FEATURES})"
BUILD_LOG="$(mktemp -t kontor-build)"
# Be a good citizen: compile at low priority on a limited number of cores, so the Mac stays usable
# while a build runs. KONTOR_BUILD_JOBS / KONTOR_BUILD_NICE override (e.g. KONTOR_BUILD_NICE=0).
JOBS="${KONTOR_BUILD_JOBS:-$(( ($(sysctl -n hw.ncpu) + 1) / 3 ))}"
[[ "$JOBS" -ge 1 ]] || JOBS=1
NICE="${KONTOR_BUILD_NICE:-15}"
if ! nice -n "$NICE" swift build -c "$CONFIG" -j "$JOBS" --scratch-path "$SCRATCH" --product Kontor > "$BUILD_LOG" 2>&1; then
    cat "$BUILD_LOG" >&2
    rm -f "$BUILD_LOG"
    echo "error: build failed" >&2
    exit 1
fi
if [[ "$QUIET" == 0 ]]; then tail -n 1 "$BUILD_LOG"; fi
# Warnings are errors by convention (zero-warning policy): show them even in quiet mode.
if grep -q "warning:" "$BUILD_LOG"; then grep "warning:" "$BUILD_LOG" | sort -u >&2; fi
rm -f "$BUILD_LOG"
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

say "▸ Assembling $APP"
# Quit a running copy of THIS bundle first (replacing a bundle under a live process confuses
# LaunchServices). Other copies — other feature bundles, an installed app — are left alone.
pkill -f "^$EXECUTABLE" 2>/dev/null && sleep 0.5 || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Kontor" "$EXECUTABLE"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# App icon: rendered by Scripts/make-icon.swift, cached (shared by all feature bundles) until that
# script changes. Rendered into a private directory and moved into place, so concurrent runs are safe.
ICON_CACHE="$ROOT/.build/icon"
ICON_STAMP="$ICON_CACHE/$(shasum "$ROOT/Scripts/make-icon.swift" | cut -c1-16).icns"
if [[ ! -f "$ICON_STAMP" ]]; then
    say "▸ Rendering app icon"
    mkdir -p "$ICON_CACHE"
    ICON_TMP="$(mktemp -d "$ICON_CACHE/render.XXXXXX")"
    swift "$ROOT/Scripts/make-icon.swift" "$ICON_TMP/AppIcon.iconset" > /dev/null
    iconutil --convert icns --output "$ICON_TMP/AppIcon.icns" "$ICON_TMP/AppIcon.iconset"
    mv -f "$ICON_TMP/AppIcon.icns" "$ICON_STAMP"
    rm -rf "$ICON_TMP"
fi
cp "$ICON_STAMP" "$APP/Contents/Resources/AppIcon.icns"

if [[ "$SANDBOX" == 1 ]]; then
    ENTITLEMENTS="$ROOT/Resources/Kontor.entitlements"
    say "▸ Signing (ad hoc, hardened runtime, App Sandbox)"
else
    ENTITLEMENTS="$ROOT/Resources/Kontor-dev.entitlements"
    say "▸ Signing (ad hoc, hardened runtime, no sandbox — development)"
fi
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" --timestamp=none "$APP" 2> /dev/null
codesign --verify --strict "$APP"

if [[ "$VERIFY" == 1 ]]; then
    say "▸ Verifying launch"
    # -g: do not bring it to the front, -j: launch hidden. Nobody working on this Mac is disturbed.
    open -n -g -j "$APP"
    alive=0
    for _ in $(seq 1 20); do
        sleep 0.25
        if pgrep -f "^$EXECUTABLE" > /dev/null; then alive=1; break; fi
    done
    sleep 2
    if [[ "$alive" == 1 ]] && pgrep -f "^$EXECUTABLE" > /dev/null; then
        say "  launched and stayed alive (pid $(pgrep -f "^$EXECUTABLE" | head -1))"
        pkill -f "^$EXECUTABLE" || true
        for _ in $(seq 1 20); do
            pgrep -f "^$EXECUTABLE" > /dev/null || break
            sleep 0.25
        done
        pkill -9 -f "^$EXECUTABLE" 2>/dev/null || true
    else
        echo "error: Kontor.app did not stay alive after launch" >&2
        exit 1
    fi
fi

say "✔ $APP ($CONFIG, $([[ "$SANDBOX" == 1 ]] && echo sandboxed || echo unsandboxed), version $VERSION)"
