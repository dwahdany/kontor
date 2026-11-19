#!/bin/bash
# Builds Kontor and runs its end-to-end self-test. Nothing appears on screen and the focus never
# changes: the in-process test hosts its windows below the desktop picture, and the document test
# launches the app hidden and in the background.
#
#   Scripts/selftest.sh [debug|release] [--quick] [--verbose] [--no-document] [--document-only]
#                       [--only scenario|documents|import|tours] [--today YYYY-MM-DD]
#
# 1. `Kontor --selftest` (in-process): builds a portfolio through the editors' own code paths
#    (accounts, depots, securities, all 15 transaction kinds), checks balances and positions with
#    the engine, undoes and redoes every step, saves and reopens through the document's read and
#    write paths, imports Portfolio Performance XML and CSV, generates plan transactions, applies
#    a rebalancing proposal, updates quotes against a stub server, then hosts the real window and
#    walks every screen, sub-view, period, scope, deep link and sheet on the starter, demo and
#    stress portfolios, and finally searches everything the process logged for runtime warnings.
# 2. `Kontor --document-selftest` (a real, hidden launch): open, edit, Save, autosave, undo,
#    Revert and edit again through AppKit's NSDocument — the paths that only exist in a running
#    document app. A watchdog reports a blocked main thread instead of hanging.
#
# debug   (default) unsandboxed bundle; Portfolio Performance fixtures from the repository are
#         imported as well.
# release sandboxed bundle; fixtures are skipped (the sandbox cannot read the repository).
# --quick skips the stress portfolio and the deeper tours (about a minute instead of several).
#
# Exit status: 0 if everything passed, 1 otherwise.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="debug"
DOCUMENT=1
INPROCESS=1
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release) CONFIG="$1" ;;
        --no-document) DOCUMENT=0 ;;
        --document-only) INPROCESS=0 ;;
        --quick|--verbose|-v) ARGS+=("$1") ;;
        --only|--today) ARGS+=("$1" "$2"); shift ;;
        *) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
    esac
    shift
done

"$ROOT/Scripts/bundle.sh" "$CONFIG" --quiet || exit 1
APP="$ROOT/dist/Kontor.app"
EXECUTABLE="$APP/Contents/MacOS/Kontor"
STATUS=0

if [[ "$INPROCESS" == 1 ]]; then
    if [[ "$CONFIG" == "debug" ]]; then
        ARGS+=(--fixtures "$ROOT/Core/Interchange/Tests/KontorInterchangeTests/Fixtures")
    fi
    nice -n "${KONTOR_BUILD_NICE:-15}" "$EXECUTABLE" --selftest ${ARGS[@]+"${ARGS[@]}"}
    CODE=$?
    if [[ $CODE -ne 0 ]]; then
        [[ $CODE -gt 1 ]] && echo "FAIL the self-test process ended abnormally (exit status $CODE) — the last line above is the step that was running" >&2
        STATUS=1
    fi
fi

if [[ "$DOCUMENT" == 1 ]]; then
    echo
    echo "== Document life cycle (hidden launch)"
    WORK="$(mktemp -d -t kontor-document-selftest)"
    OUT="$WORK/stdout.txt"
    # -g: never comes to the front, -j: launched hidden, -n: its own instance. The sandboxed
    # release build writes its files inside its container ("auto").
    if [[ "$CONFIG" == "release" ]]; then TARGET="auto"; else TARGET="$WORK/files"; fi
    open -n -g -j "$APP" --stdout "$OUT" --stderr "$WORK/stderr.txt" --args \
        --document-selftest "$TARGET" -marketData.autoUpdateOnOpen NO -general.showWelcomeAtLaunch NO -ApplePersistenceIgnoreState YES
    for _ in $(seq 1 240); do
        sleep 0.5
        if grep -q "^RESULT " "$OUT" 2>/dev/null; then break; fi
        if ! pgrep -f "^$EXECUTABLE --document-selftest" > /dev/null; then sleep 0.5; break; fi
    done
    pkill -f "^$EXECUTABLE --document-selftest" 2>/dev/null || true
    grep -v "^RESULT " "$OUT" 2>/dev/null || true
    if grep -q "^RESULT pass" "$OUT" 2>/dev/null; then
        echo "PASS — document life cycle"
    else
        echo "FAIL — document life cycle (no passing result; stderr follows)"
        grep -v "ApplePersistenceIgnoreState" "$WORK/stderr.txt" 2>/dev/null | head -20
        STATUS=1
    fi
    rm -rf "$WORK"
fi

exit $STATUS
