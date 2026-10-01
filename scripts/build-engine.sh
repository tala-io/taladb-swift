#!/usr/bin/env bash
# Build the TalaDB engine from a local checkout of tala-io/taladb and stage it
# in engine/, where Package.swift looks for it.
#
#   Linux:  engine/include/taladb.h and engine/host/libtaladb_ffi.so, for the
#           system-library module and scripts/test-linux.sh
#   macOS:  engine/TalaDBFFI.xcframework (iOS device, iOS simulator, macOS),
#           used while Package.swift pins no engine release
#
# Usage: scripts/build-engine.sh [path-to-taladb-checkout]   default: ../taladb
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$(cd "${1:-${TALADB_ENGINE_SRC:-$ROOT/../taladb}}" && pwd)"
FFI="$SRC/packages/bindings/ffi"
OUT="$ROOT/engine"

[[ -f "$FFI/include/module.modulemap" ]] || {
    echo "error: $SRC has no packages/bindings/ffi/include/module.modulemap" >&2
    echo "       (needs an engine with C ABI version 2)" >&2
    exit 1
}
TARGET_DIR="$(cargo metadata --manifest-path "$FFI/Cargo.toml" --no-deps --format-version 1 |
    python3 -c 'import sys, json; print(json.load(sys.stdin)["target_directory"])')"

rm -rf "$OUT"
mkdir -p "$OUT/include"
cp "$FFI/include/taladb.h" "$FFI/include/module.modulemap" "$OUT/include/"

build() { cargo build --manifest-path "$FFI/Cargo.toml" --release "$@"; }

case "$(uname -s)" in
    Darwin)
        targets=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin)
        rustup target add "${targets[@]}"
        for t in "${targets[@]}"; do build --target "$t"; done
        lib() { echo "$TARGET_DIR/$1/release/libtaladb_ffi.a"; }
        WORK="$(mktemp -d)"
        trap 'rm -rf "$WORK"' EXIT
        lipo -create "$(lib aarch64-apple-ios-sim)" "$(lib x86_64-apple-ios)" -output "$WORK/sim.a"
        lipo -create "$(lib aarch64-apple-darwin)" "$(lib x86_64-apple-darwin)" -output "$WORK/macos.a"
        xcodebuild -create-xcframework \
            -library "$(lib aarch64-apple-ios)" -headers "$OUT/include" \
            -library "$WORK/sim.a" -headers "$OUT/include" \
            -library "$WORK/macos.a" -headers "$OUT/include" \
            -output "$OUT/TalaDBFFI.xcframework"
        ;;
    *)
        build
        mkdir -p "$OUT/host"
        cp "$TARGET_DIR/release/libtaladb_ffi.so" "$OUT/host/"
        ;;
esac

echo "local $(git -C "$SRC" describe --always --dirty) ($SRC)" > "$OUT/SOURCE"
echo "Staged engine from $(cat "$OUT/SOURCE") in $OUT"
