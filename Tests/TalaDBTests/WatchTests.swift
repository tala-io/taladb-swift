import Foundation
import XCTest

@testable import TalaDB

final class WatchTests: DatabaseTestCase {
    func testYieldsTheCurrentStateThenEachChange() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        try await notes.insert(Note(title: "a"))

        var iterator = notes.watch().makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.map(\.title), ["a"])

        // Written through a different collection value on the same database.
        try await db.collection("notes", as: Note.self).insert(Note(title: "b"))
        let second = try await iterator.next()
        XCTAssertEqual(Set(second?.map(\.title) ?? []), ["a", "b"])
    }

    func testAppliesTheFilterAndSkipsWritesThatChangeNothing() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)

        var iterator = notes.watch(["stars": 5]).makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.count, 0)

        try await notes.insert(Note(title: "meh", stars: 1))
        try await notes.insert(Note(title: "great", stars: 5))
        // The non-matching write produced no element: the next one is "great".
        let next = try await iterator.next()
        XCTAssertEqual(next?.map(\.title), ["great"])
    }

    /// More writes than the engine's 64-event channel, while the consumer is behind.
    func testSurvivesABurstOfWritesAndEndsOnTheLatestState() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        var iterator = notes.watch().makeAsyncIterator()
        _ = try await iterator.next()

        for i in 0..<200 { try await notes.insert(Note(title: "n\(i)")) }

        while let snapshot = try await iterator.next(), snapshot.count != 200 {}
    }

    func testSlowConsumerReceivesTheLatestSnapshot() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        var iterator = notes.watch().makeAsyncIterator()
        _ = try await iterator.next()

        // Let the producer observe separate writes while the consumer is idle.
        // An unbounded stream keeps every full snapshot and next() returns 1.
        for i in 0..<3 {
            try await notes.insert(Note(title: "n\(i)"))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let latest = try await iterator.next()
        XCTAssertEqual(latest?.count, 3)
    }

    /// close() must end live queries and release the file — a watch holds the
    /// storage open, so a lingering one would make the reopen below fail.
    func testClosingTheDatabaseEndsTheStreamAndReleasesTheFile() async throws {
        let db = try await TalaDB.open(at: file())
        let notes = db.collection("notes", as: Note.self)
        var iterator = notes.watch().makeAsyncIterator()
        _ = try await iterator.next()

        db.close()
        do {
            while try await iterator.next() != nil {}
            XCTFail("the stream must end by throwing")
        } catch {
            XCTAssertEqual(error as? TalaDBError, .closed)
        }

        let reopened = try await TalaDB.open(at: file())
        reopened.close()
    }

    func testCancellingTheConsumerClosesTheSubscription() async throws {
        let db = try await TalaDB.open(at: file())
        let notes = db.collection("notes", as: Note.self)
        let consumer = Task {
            for try await _ in notes.watch() {}
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        consumer.cancel()
        _ = await consumer.result

        db.close()
        let reopened = try await TalaDB.open(at: file())
        reopened.close()
    }

    /// A screen's live queries start while others are running. Each running
    /// one waits on the engine in 250 ms polls; when subscribing had to wait
    /// for every in-flight poll, a new live query's first result took a poll
    /// or more.
    func testANewLiveQueryDoesNotWaitBehindRunningOnes() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        try await notes.insert(Note(title: "a"))
        let running = (0..<5).map { _ in Task { for try await _ in notes.watch() {} } }
        defer { running.forEach { $0.cancel() } }
        try await Task.sleep(nanoseconds: 500_000_000) // every running query is inside a native wait

        var worstMs = 0.0
        for _ in 0..<5 {
            let start = Date()
            var iterator = notes.watch().makeAsyncIterator()
            _ = try await iterator.next()
            worstMs = max(worstMs, Date().timeIntervalSince(start) * 1000)
            try await Task.sleep(nanoseconds: 73_000_000) // land at different points in the running polls
        }
        XCTAssertLessThan(worstMs, 150, "a new live query took \(Int(worstMs)) ms to deliver its first result")
    }
}
