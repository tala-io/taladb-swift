/// An application schema migration, run once by `TalaDB.open` when `version`
/// is above the database's stored ``TalaDB/userVersion()``.
///
/// ```swift
/// let db = try await TalaDB.open(at: url, migrations: [
///     Migration(1, "Index users by email") { db in
///         try await db.collection("users").createIndex("email")
///     },
///     Migration(2, "Default role") { db in
///         try await db.collection("users").updateMany(
///             ["role": ["$exists": false]],
///             ["$set": ["role": "user"]]
///         )
///     },
/// ])
/// ```
///
/// The stored version advances after each migration completes — a checkpoint
/// per version, not one transaction for the batch. A migration that fails
/// halfway keeps the writes it made and runs again from the top on the next
/// open, so write `up` to be safe to repeat. Index creation already is.
///
/// Never change a migration that has shipped: a device that ran it will not
/// run it again. Add one with a higher version instead. Versions may have gaps;
/// version 1 is effectively the initial schema of a fresh install.
public struct Migration: Sendable {
    public let version: UInt32
    public let description: String
    public let up: @Sendable (TalaDB) async throws -> Void

    public init(_ version: UInt32, _ description: String = "", up: @escaping @Sendable (TalaDB) async throws -> Void) {
        self.version = version
        self.description = description
        self.up = up
    }

    /// Sorted by version; throws before anything is opened if the list is malformed.
    static func validated(_ migrations: [Migration]) throws -> [Migration] {
        let sorted = migrations.sorted { $0.version < $1.version }
        for (i, m) in sorted.enumerated() {
            guard m.version >= 1 else {
                throw TalaDBError.invalidArgument("migration version must be at least 1")
            }
            if i > 0, sorted[i - 1].version == m.version {
                throw TalaDBError.invalidArgument("duplicate migration version \(m.version)")
            }
        }
        return sorted
    }
}
