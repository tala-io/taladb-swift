#!/usr/bin/env bash
# Build and run a throwaway app that depends on this package the way the README
# tells users to — `.product(name: "TalaDB", package: "taladb-swift")` — so a
# release tag never discovers a product, identity or public-API problem that
# the package's own tests cannot see. Nothing is published.
#
# Linux: run scripts/build-engine.sh first; the app links engine/host like
# scripts/test-linux.sh does. macOS: uses whatever Package.swift resolves.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A path dependency's identity is its directory name, so link the checkout
# under the name users resolve it by.
ln -s "$ROOT" "$WORK/taladb-swift"
mkdir -p "$WORK/app/Sources/App"

cat > "$WORK/app/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "App",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    dependencies: [.package(path: "../taladb-swift")],
    targets: [
        .executableTarget(name: "App", dependencies: [.product(name: "TalaDB", package: "taladb-swift")])
    ]
)
SWIFT

cat > "$WORK/app/Sources/App/main.swift" <<'SWIFT'
import Foundation
import TalaDB

struct Note: Codable, Sendable {
    var id: String?
    var title: String
    enum CodingKeys: String, CodingKey { case id = "_id", title }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

let db = try await TalaDB.open(at: dir.appendingPathComponent("app.db"))
let notes = db.collection("notes", as: Note.self)
let id = try await notes.insert(Note(title: "hello"))
let found = try await notes.find()
precondition(found.count == 1 && found[0].id == id && found[0].title == "hello", "round trip failed: \(found)")
db.close()
print("OK: an app depending on taladb-swift builds, links and round-trips a document")
SWIFT

args=()
if [[ "$(uname -s)" != Darwin ]]; then
    HOST="$ROOT/engine/host"
    [[ -f "$HOST/libtaladb_ffi.so" ]] || { echo "error: run scripts/build-engine.sh first" >&2; exit 1; }
    args=(-Xlinker -L"$HOST" -Xlinker -rpath -Xlinker "$HOST")
fi
cd "$WORK/app"
swift run "${args[@]}" App
