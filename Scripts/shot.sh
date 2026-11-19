#!/bin/bash
# Builds the app with ONE feature compiled in (isolated from everybody else's work in progress) and
# renders a screenshot of it.
#
#   Scripts/shot.sh <Feature|all> <screen-id> <out.png|out-dir/> [extra app arguments…]
#
#   Scripts/shot.sh Holdings holdings /tmp/holdings.png
#   Scripts/shot.sh Holdings holdings /tmp/holdings/ --appearance both --today 2026-06-30
#   Scripts/shot.sh Allocation allocation /tmp/rebalance.png --state tab=rebalancing
#   Scripts/shot.sh Transactions holdings /tmp/editor.png --sheet new-transaction:buy
#   Scripts/shot.sh Performance performance /tmp/perf.png --stress          # 50,000 transactions, prints timing
#   Scripts/shot.sh all all /tmp/everything/ --appearance both               # the full app, every target
#
# <Feature>    Dashboard Holdings Performance Earnings Trades Allocation Securities Transactions
#              Accounts Plans Import — or a comma-separated list, "none" (bare shell), or "all".
#              Features that are not listed are not compiled; their screens show the placeholder.
# <screen-id>  dashboard holdings performance allocation earnings trades securities transactions
#              accounts plans import · welcome palette settings portfolio-settings consistency
#              quote-report · all
#
# Each selection has its own build directory (.build-<feature>) and bundle (dist-<feature>/), so
# any number of these can run at the same time. The demo portfolio is used unless you pass --open,
# --stress or --demo yourself. All other arguments go to the app (`Kontor --help` lists them).
set -euo pipefail

usage() {
    sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 64
}
[[ $# -ge 3 ]] || usage

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURE="$1"
SCREEN="$2"
OUT="$3"
shift 3

SELECTION="$(printf '%s' "$FEATURE" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
if [[ "$SELECTION" == "all" ]]; then
    unset KONTOR_FEATURES
    APP="$ROOT/dist/Kontor.app"
else
    export KONTOR_FEATURES="$FEATURE"
    APP="$ROOT/dist-$(printf '%s' "$SELECTION" | tr ',' '-')/Kontor.app"
fi

"$ROOT/Scripts/bundle.sh" debug --no-verify --quiet

DATA=(--demo)
for arg in "$@"; do
    case "$arg" in --demo|--stress|--open) DATA=() ;; esac
done

# Relative output paths are relative to where the script was called from.
exec nice -n "${KONTOR_BUILD_NICE:-15}" "$APP/Contents/MacOS/Kontor" --screenshot "$SCREEN" --out "$OUT" ${DATA[@]+"${DATA[@]}"} "$@"
