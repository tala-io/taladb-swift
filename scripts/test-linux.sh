#!/usr/bin/env bash
# Run the test suite on Linux against the engine staged by scripts/build-engine.sh.
# Extra arguments go to `swift test`, e.g. --filter WatchTests.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$ROOT/engine/host"
[[ -f "$HOST/libtaladb_ffi.so" ]] || { echo "error: run scripts/build-engine.sh first" >&2; exit 1; }
cd "$ROOT"
exec swift test -Xlinker -L"$HOST" -Xlinker -rpath -Xlinker "$HOST" "$@"
