import Foundation
import XCTest
@testable import TalaDB

/// Records which migrations ran, across @Sendable closures.
final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UInt32] = []
    func add(_ v: UInt32) { lock.lock(); entries.append(v); lock.unlock() }
    func take() -> [UInt32] { lock.lock(); defer { entries = []; lock.unlock() }; return entries }
}

final class MigrationTests: DatabaseTestCase {
    func testRunsPendingMigrationsInVersionOrderOnce() async throws {
        let log = RunLog()
        func m(_ v: UInt32) -> Migration { Migration(v, "v\(v)") { _ in log.add(v) } }

        // Declared out of order on purpose; they run sorted.
        var db = try await TalaDB.open(at: file(), migrations: [m(3), m(1)])
        var version = try await db.userVersion()
        XCTAssertEqual(version, 3)
        db.close()
        XCTAssertEqual(log.take(), [1, 3])

        db = try await TalaDB.open(at: file(), migrations: [m(1), m(3), m(4)])
        version = try await db.userVersion()
        XCTAssertEqual(version, 4)
        db.close()
        XCTAssertEqual(log.take(), [4], "only the new migration runs")
    }

    func testAFailedMigrationClosesTheDatabaseAndResumesThereNextTime() async throws {
        struct Boom: Error {}
        let log = RunLog()
        let failing = [
            Migration(1) { _ in log.add(1) },
            Migration(2) { _ in log.add(2); throw Boom() },
            Migration(3) { _ in log.add(3) },
        ]
        await assertThrowsAsync(try await TalaDB.open(at: file(), migrations: failing)) { $0 is Boom }
        XCTAssertEqual(log.take(), [1, 2])

        // The failed open closed its handle, so the file can be reopened.
        let fixed = [Migration(1) { _ in log.add(1) }, Migration(2) { _ in log.add(2) }, Migration(3) { _ in log.add(3) }]
        let db = try await TalaDB.open(at: file(), migrations: fixed)
        let version = try await db.userVersion()
        XCTAssertEqual(version, 3)
        db.close()
        XCTAssertEqual(log.take(), [2, 3], "resumes at the failed migration")
    }

    func testMigrationsSeeTheDatabaseAndTheirWritesPersist() async throws {
        let seed = Migration(1, "seed") { db in
            try await db.collection("users").createIndex("email")
            try await db.collection("users").insert(["email": "a@b.c"])
        }
        let db = try await TalaDB.open(at: file(), migrations: [seed])
        defer { db.close() }
        let indexes = try await db.collection("users").listIndexes()
        XCTAssertEqual(indexes.btree, ["email"])
    }

    func testMalformedMigrationListsFailBeforeAnythingOpens() async throws {
        for bad in [[Migration(1) { _ in }, Migration(1) { _ in }], [Migration(0) { _ in }]] {
            await assertThrowsAsync(try await TalaDB.open(at: file(), migrations: bad)) {
                if case TalaDBError.invalidArgument = $0 { return true }
                return false
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file().path))
    }
}
