#!/bin/bash
# Builds the debug bundle and opens it. Arguments are files to open with it:
#   Scripts/run.sh                         # launch normally (welcome window)
#   Scripts/run.sh /path/to/file.kontor    # open a document
#   Scripts/run.sh /path/to/export.csv     # hand a file to the importer
#
# With KONTOR_FEATURES set, only those features are compiled (own scratch directory and bundle):
#   KONTOR_FEATURES=Holdings Scripts/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/bundle.sh" debug --no-verify
SELECTION="$(printf '%s' "${KONTOR_FEATURES-all}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
if [[ -z "${KONTOR_FEATURES+x}" || "$SELECTION" == "all" ]]; then
    APP="$ROOT/dist/Kontor.app"
else
    APP="$ROOT/dist-$(printf '%s' "${SELECTION:-none}" | tr ',' '-')/Kontor.app"
fi
if [[ $# -gt 0 ]]; then
    open -n -a "$APP" "$@"
else
    open -n "$APP"
fi
