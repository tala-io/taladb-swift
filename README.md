<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/tala-db-dark.png">
  <img src=".github/assets/tala-db.png" alt="TalaDB" width="240">
</picture>

# TalaDB for Swift

Swift bindings for [TalaDB](https://github.com/taladb/taladb), an embedded
document and vector database, for native iOS and macOS apps that do not use
React Native.

Documents, MongoDB-style filters and updates, secondary and compound indexes,
full-text search, vector search and hybrid search, live queries, migrations,
and optional encryption at rest. Everything runs on the device in a single file.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/taladb/taladb-swift", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "TalaDB", package: "taladb-swift")]),
]
```

iOS 13+ and macOS 10.15+, through Swift Package Manager. The engine ships as
a prebuilt `TalaDBFFI.xcframework`, which SwiftPM downloads and verifies by
checksum.

## Use

```swift
import TalaDB

struct Note: Codable, Sendable {
    var id: String?
    var title: String
    var tags: [String] = []
    var embedding: [Float] = []
    enum CodingKeys: String, CodingKey { case id = "_id", title, tags, embedding }
}

let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("app.db")
let db = try await TalaDB.open(at: url)          // keep one per process
let notes = db.collection("notes", as: Note.self)

let id = try await notes.insert(Note(title: "Groceries", tags: ["home"]))
let home = try await notes.find(["tags": "home"])
try await notes.updateOne(["_id": .string(id)], ["$set": ["title": "Weekly groceries"]])

// Vector search over embeddings from any on-device model
try await notes.createVectorIndex("embedding", dimensions: 384)
let similar = try await notes.findNearest("embedding", vector: queryVector, topK: 5)

// Full-text and hybrid search
try await notes.createFtsIndex("title")
let hits = try await notes.hybridSearch(textField: "title", text: "groceries",
                                        vectorField: "embedding", vector: queryVector, topK: 5)
```

Every operation is `async` and runs off the calling thread, so it is safe to
call from the main actor. One `TalaDB` can be shared freely across tasks.

- **Filters, updates and pipelines** are `JSONValue` literals using TalaDB's
  operators — `$eq`, `$gt`, `$in`, `$exists`, `$contains`, `$set`, `$inc`,
  `$push`, `$group`, … — documented in the [engine docs](https://taladb.dev).
- **`_id`**: every document has one. Leave it nil on insert and the engine
  assigns a ULID.
- **Untyped access**: `db.collection("name")` works with raw `JSONValue` objects.
- **Encryption**: `TalaDB.open(at: url, config: TalaDBConfig(passphrase: key))`.
  The config's `description` never prints the passphrase.
- **Errors**: engine errors (bad filter, missing index, wrong passphrase,
  duplicate `_id`) throw `TalaDBError.engine`; calls after `close()` throw
  `.closed`.
- **Closing**: `close()` waits for running operations and is idempotent. A
  database also closes when its last reference goes away.

### Live queries

`watch` returns an `AsyncThrowingStream`. It yields the current result, then a
fresh one after every write that changes it. Rapid writes coalesce into one
element, and nothing is missed:

```swift
for try await open in notes.watch(["done": false]) {
    render(open)
}
```

Each iteration holds its own subscription, which closes when the task is
cancelled or the loop exits.

### Migrations

```swift
let db = try await TalaDB.open(at: url, migrations: [
    Migration(1, "Index users by email") { db in
        try await db.collection("users").createIndex("email")
    },
    Migration(2, "Default role") { db in
        try await db.collection("users").updateMany(["role": ["$exists": false]],
                                                    ["$set": ["role": "user"]])
    },
])
```

Pending migrations run in version order at open. The stored version advances
after each one, so a failure resumes from the failed migration on the next
open. Write migrations so they are safe to run again.

### Vector search, in depth

`searchVectors` adds exact or approximate mode, `efSearch`, score thresholds,
pagination and grouping, and reports how the query ran.
`rebuildVectorIndex` builds an HNSW graph in batches, reporting progress, and
can be cancelled with the task. `measureVectorRecall` checks approximate
results against exact search on your own query embeddings.

## How it works

```
Swift API (TalaDB, TalaCollection)           Sources/TalaDB, this repo
  └─ import TalaDBFFI  ──►  libtaladb_ffi      the engine's C FFI, from taladb/taladb
```

Swift calls the engine's C interface directly. No shim is needed: the
xcframework carries `taladb.h` and a module map. Most operations go through
the engine's `taladb_call(op, args_json)`. Only vector calls pass a `[Float]`
buffer directly. At open, the package checks that the library's C ABI version
matches the header it was compiled against, so an engine/package mismatch
fails with `TalaDBError.incompatibleEngine` instead of corrupting memory.

## Development

You need Rust and a checkout of [taladb/taladb](https://github.com/taladb/taladb).

**On a Mac:**

```sh
scripts/build-engine.sh ../taladb    # builds engine/TalaDBFFI.xcframework
swift test                           # macOS; open Package.swift in Xcode for iOS
```

**On Linux** the engine is linked as a system library, so the full test suite
runs without Apple hardware:

```sh
scripts/build-engine.sh ../taladb    # stages engine/include and engine/host
scripts/test-linux.sh
```

## Releasing

1. When the engine publishes a release, its workflow dispatches to this repo
   and `engine-bump.yml` opens a PR. The PR sets `engineURL` and
   `engineChecksum` in `Package.swift`. CI tests it on Linux, macOS and an
   iOS simulator.
2. Tag `X.Y.Z` (SwiftPM tags carry no `v`). The package is published by the
   tag itself.

The engine repository needs `NATIVE_PACKAGES_DISPATCH_TOKEN` to send the
release notification.

## License

MIT or Apache-2.0, at your option.
