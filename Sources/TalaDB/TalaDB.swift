import Foundation
import TalaDBFFI

/// An open TalaDB database: an embedded document store with secondary,
/// full-text and vector indexes, stored in a single file.
///
/// Open one with ``open(at:config:migrations:)`` and keep it for the life of
/// the process — it is safe to share across tasks and threads. Every operation
/// is `async` and runs off the calling thread, so it is safe to call from the
/// main actor.
///
/// Call ``close()`` when done, or let the last reference go. Operations already
/// running finish first; anything called afterwards throws `TalaDBError.closed`.
public final class TalaDB: @unchecked Sendable {
    // Every access to `handle` and `watches` happens on `queue`. Operations
    // run as ordinary concurrent blocks; close() and the watch bookkeeping run
    // as barriers, which wait for in-flight operations and exclude new ones —
    // a read/write lock without a lock. Without it, close() on one thread
    // while another is mid-call frees the handle under it.
    private let queue = DispatchQueue(label: "dev.taladb.database", attributes: .concurrent)
    private var handle: OpaquePointer?
    // Native live-query handles. Each keeps the database's storage open, so
    // close() closes them all rather than leaving the file held until each
    // stream next wakes.
    private var watches: Set<LiveQueryHandle> = []

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        // Not closeNow(): deinit runs on whichever thread drops the last
        // reference, and that is often a block on `queue` itself — a
        // queue.sync there waits on itself, which libdispatch traps. No other
        // reference exists by now, so nothing else can touch the handle.
        for watch in watches { taladb_watch_close(watch.pointer) }
        if let handle { taladb_close(handle) }
    }

    /// Open the database at `url`, creating it if it does not exist, and run
    /// any pending `migrations` before returning.
    ///
    /// Migrations with a version above the stored ``userVersion()`` run in
    /// version order, and the stored version advances after each. If one
    /// throws, the database is closed, the error propagates, and the next open
    /// resumes from that migration. See ``Migration``.
    public static func open(
        at url: URL,
        config: TalaDBConfig = TalaDBConfig(),
        migrations: [Migration] = []
    ) async throws -> TalaDB {
        let pending = try Migration.validated(migrations)
        try checkEngineCompatibility()
        let configJSON = try config.json()
        let db: TalaDB = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        let handle = try withCStrings([url.path, configJSON]) { p in
                            taladb_open_with_config(p[0], p[1])
                        }
                        guard let handle else { throw engineError("failed to open database") }
                        return TalaDB(handle: handle)
                    })
            }
        }
        do {
            let current = try await db.userVersion()
            for migration in pending where migration.version > current {
                try await migration.up(db)
                try await db.setUserVersion(migration.version)
            }
        } catch {
            db.close()
            throw error
        }
        return db
    }

    /// The C ABI version of the loaded engine library.
    public static var engineABIVersion: UInt32 { taladb_ffi_abi_version() }

    private static func checkEngineCompatibility() throws {
        let header = UInt32(TALADB_FFI_ABI_VERSION)
        let library = taladb_ffi_abi_version()
        guard header == library else { throw TalaDBError.incompatibleEngine(header: header, library: library) }
    }

    /// The collection `name`, with documents as raw ``JSONValue`` objects.
    public func collection(_ name: String) -> TalaCollection<JSONValue> {
        TalaCollection(database: self, name: name)
    }

    /// The collection `name`, with documents decoded as `type`. Collections
    /// are created on first write; this does no I/O.
    public func collection<Document>(_ name: String, as type: Document.Type) -> TalaCollection<Document> {
        TalaCollection(database: self, name: name)
    }

    /// Names of every collection that holds data, excluding reserved `_`-prefixed ones.
    public func collectionNames() async throws -> [String] {
        try await call("listCollectionNames", [], as: [String].self)
    }

    /// The application's schema version, as last set by ``setUserVersion(_:)``; 0 if never set.
    public func userVersion() async throws -> UInt32 {
        try await call("userVersion", [], as: UInt32.self)
    }

    /// Record the application's schema version, for running migrations once.
    public func setUserVersion(_ version: UInt32) async throws {
        _ = try await call("setUserVersion", [String(version)], as: JSONValue.self)
    }

    /// Force batched writes to disk. A no-op unless opened with `flushEveryWrite: false`.
    public func flush() async throws {
        _ = try await call("flush", [], as: JSONValue.self)
    }

    /// Reclaim unused space in the database file.
    public func compact() async throws {
        _ = try await call("compact", [], as: JSONValue.self)
    }

    /// Rebuild every persistent HNSW graph. Reads and re-inserts every indexed
    /// vector, so run it for maintenance or migration, not on a hot path.
    public func rebuildVectorIndexes() async throws {
        _ = try await call("rebuildVectorIndexes", [], as: JSONValue.self)
    }

    /// `true` once ``close()`` has run.
    public var isClosed: Bool {
        queue.sync { handle == nil }
    }

    /// Close the database. Waits for running operations to finish; idempotent.
    /// Blocks the calling thread for that wait.
    public func close() {
        closeNow()
    }

    private func closeNow() {
        queue.sync(flags: .barrier) {
            guard let handle else { return }
            for watch in watches { taladb_watch_close(watch.pointer) }
            watches.removeAll()
            taladb_close(handle)
            self.handle = nil
        }
    }

    // MARK: - Plumbing

    /// Run `body` against the live handle on the database queue. Encoding
    /// arguments and decoding results happen inside `body`, so neither runs on
    /// the caller's thread.
    func run<R: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> R) async throws -> R {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let handle = self.handle else {
                    continuation.resume(throwing: TalaDBError.closed)
                    return
                }
                continuation.resume(with: Result { try body(handle) })
            }
        }
    }

    /// Run a dispatch-table operation. `args` are JSON texts after the op name.
    func call<R: Decodable & Sendable>(
        _ op: String,
        _ args: @autoclosure @escaping @Sendable () throws -> [String],
        as type: R.Type
    ) async throws -> R {
        try await run { handle in
            let json = jsonArray(try args())
            let result = try withCStrings([op, json]) { p in taladb_call(handle, p[0], p[1]) }
            return try decodeJSON(type, from: try takeString(result, "\(op) failed"))
        }
    }

    // MARK: - Live queries (used by TalaCollection.watch)

    func watchOpen(collection: String, filter: String) async throws -> LiveQueryHandle {
        try await withCheckedThrowingContinuation { continuation in
            queue.async(flags: .barrier) {
                continuation.resume(
                    with: Result {
                        guard let handle = self.handle else { throw TalaDBError.closed }
                        let watch = try withCStrings([collection, filter]) { p in taladb_watch(handle, p[0], p[1]) }
                        guard let watch else { throw engineError("failed to open live query") }
                        let live = LiveQueryHandle(pointer: watch)
                        self.watches.insert(live)
                        return live
                    })
            }
        }
    }

    /// Wait up to `timeoutMs` for a write. Returns the new snapshot's JSON, or
    /// nil on timeout. Runs as an ordinary block, so close() waits at most one
    /// timeout for it.
    func watchNext(_ watch: LiveQueryHandle, timeoutMs: UInt32) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(
                    with: Result {
                        guard self.handle != nil, self.watches.contains(watch) else { throw TalaDBError.closed }
                        var out: UnsafeMutablePointer<CChar>?
                        switch taladb_watch_next(watch.pointer, timeoutMs, &out) {
                        case 0: return nil
                        case 1: return try takeString(out, "live query failed")
                        default: throw engineError("live query failed")
                        }
                    })
            }
        }
    }

    /// Idempotent: close() may already have closed it.
    func watchClose(_ watch: LiveQueryHandle) {
        queue.async(flags: .barrier) {
            if self.watches.remove(watch) != nil { taladb_watch_close(watch.pointer) }
        }
    }
}

/// A native live-query handle. Sendable because it is only ever dereferenced
/// on the owning database's queue, which serialises it against close().
struct LiveQueryHandle: @unchecked Sendable, Hashable {
    let pointer: OpaquePointer
}
