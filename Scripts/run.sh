#!/bin/bash
# Builds the debug bundle and opens it. Arguments are files to open with it:
#   Scripts/run.sh                         # launch normally (welcome window)
#   Scripts/run.sh /path/to/file.kontor    # open a document
#   Scripts/run.sh /path/to/export.csv     # hand a file to the importer
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/bundle.sh" debug --no-verify
if [[ $# -gt 0 ]]; then
    open -a "$ROOT/dist/Kontor.app" "$@"
else
    open "$ROOT/dist/Kontor.app"
fi
