import Foundation
import XCTest
@testable import TalaDB

final class TalaDBTests: DatabaseTestCase {
    func testEngineLibraryMatchesTheHeaderThePackageWasBuiltAgainst() {
        XCTAssertEqual(TalaDB.engineABIVersion, 2)
    }

    func testTypedDocumentsRoundTripWithTheirAssignedId() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        let id = try await notes.insert(Note(title: "first", stars: 3))

        let found = try await notes.findOne(["title": "first"])
        XCTAssertEqual(found, Note(id: id, title: "first", stars: 3))
        let missing = try await notes.findOne(["title": "missing"])
        XCTAssertNil(missing)
    }

    func testTextOutsideTheBasicMultilingualPlaneSurvivesTheRoundTrip() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes 📓", as: Note.self)
        let title = "café 日本語 🎉👩🏽‍💻 𝔘𝔫𝔦𝔠𝔬𝔡𝔢"
        try await notes.insert(Note(title: title, body: "nul\u{0}inside"))

        let found = try await notes.findOne(["title": .string(title)])
        XCTAssertEqual(found?.title, title)
        XCTAssertEqual(found?.body, "nul\u{0}inside")
        let names = try await db.collectionNames()
        XCTAssertTrue(names.contains("notes 📓"))
    }

    func testNULInACStringArgumentIsRejectedRatherThanTruncated() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        await assertThrowsAsync(try await db.collection("a\u{0}b").findNearest("v", vector: [1], topK: 1)) {
            if case TalaDBError.invalidArgument = $0 { return true }
            return false
        }
    }

    func testFiltersUpdatesAndDeletesReportWhatTheyTouched() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        try await notes.insertMany((1...5).map { Note(title: "n\($0)", stars: $0) })

        let total = try await notes.count()
        XCTAssertEqual(total, 5)
        let threeUp = try await notes.count(["stars": ["$gte": 3]])
        XCTAssertEqual(threeUp, 3)

        let updated = try await notes.updateOne(["title": "n1"], ["$set": ["body": "edited"]])
        XCTAssertTrue(updated)
        let none = try await notes.updateOne(["title": "nope"], ["$set": ["body": "x"]])
        XCTAssertFalse(none)
        let edited = try await notes.findOne(["title": "n1"])
        XCTAssertEqual(edited?.body, "edited")

        let bumped = try await notes.updateMany(["stars": ["$lt": 3]], ["$inc": ["stars": 10]])
        XCTAssertEqual(bumped, 2)

        let deleted = try await notes.deleteOne(["title": "n5"])
        XCTAssertTrue(deleted)
        let again = try await notes.deleteOne(["title": "n5"])
        XCTAssertFalse(again)
        let rest = try await notes.deleteMany([:])
        XCTAssertEqual(rest, 4)
    }

    func testDocumentsCanBeAddressedByTheirId() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        let id = try await notes.insert(Note(title: "Groceries"))
        try await notes.insert(Note(title: "Other"))

        try await notes.updateOne(["_id": .string(id)], ["$set": ["title": "Weekly groceries"]])
        let found = try await notes.findOne(["_id": .string(id)])
        XCTAssertEqual(found?.title, "Weekly groceries")
    }

    func testInsertManyWritesNothingWhenAnyDocumentIsRejected() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        let id = try await notes.insert(Note(title: "existing"))

        await assertThrowsAsync(try await notes.insertMany([Note(title: "new"), Note(id: id, title: "duplicate")]), isEngineError)
        let count = try await notes.count()
        XCTAssertEqual(count, 1)
    }

    func testUntypedCollectionsUseJSONValue() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let raw = db.collection("raw")
        try await raw.insert(["a": 1, "xs": [1, 2], "f": 1.5])
        let doc = try await raw.findOne()
        XCTAssertEqual(doc?["a"], .int(1))
        XCTAssertEqual(doc?["f"], .double(1.5))
        XCTAssertNotNil(doc?["_id"]?.stringValue)
    }

    func testDocumentsMustEncodeToAnObject() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        await assertThrowsAsync(try await db.collection("strings", as: String.self).insert("not an object")) {
            if case TalaDBError.invalidArgument = $0 { return true }
            return false
        }
    }

    func testIndexErrorsFromTheEngineAreThrown() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        try await notes.createIndex("title")
        try await notes.createIndex("title")
        try await notes.createCompoundIndex(["stars", "title"])
        try await notes.createFtsIndex("body")
        let info = try await notes.listIndexes()
        XCTAssertTrue(info.btree.contains("title"))
        XCTAssertEqual(info.fts, ["body"])

        try await notes.dropIndex("title")
        await assertThrowsAsync(try await notes.dropIndex("title"), isEngineError)
        try await notes.dropCompoundIndex(["stars", "title"])
        try await notes.dropFtsIndex("body")
    }

    func testAggregationGroupsAndSorts() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        try await notes.insertMany([Note(title: "a", stars: 1), Note(title: "a", stars: 2), Note(title: "b", stars: 5)])
        let rows = try await notes.aggregate([
            ["$group": ["_id": "$title", "total": ["$sum": "$stars"]]],
            ["$sort": ["_id": 1]],
        ])
        XCTAssertEqual(rows.compactMap { $0["total"]?.intValue }, [3, 5])
    }

    func testFullTextSearchRanksMatchingDocuments() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let docs = db.collection("docs", as: Doc.self)
        try await docs.createFtsIndex("text")
        try await docs.insertMany([
            Doc(title: "rust", text: "rust ownership and borrowing"),
            Doc(title: "swift", text: "swift concurrency and actors"),
            Doc(title: "both", text: "calling rust from swift over c"),
        ])
        let hits = try await docs.searchText("text", query: "rust", topK: 10)
        XCTAssertEqual(Set(hits.map(\.document.title)), ["rust", "both"])
    }

    /// JSONEncoder writes Float 1.0 as `1`, so embeddings reach the engine as
    /// integers; vector search must still work.
    func testVectorSearchWorksWithIntegerLookingEmbeddings() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let docs = db.collection("docs", as: Doc.self)
        try await docs.createVectorIndex("embedding", dimensions: 3)
        try await docs.insertMany([
            Doc(title: "x", kind: "a", embedding: [1, 0, 0]),
            Doc(title: "y", kind: "b", embedding: [0, 1, 0]),
            Doc(title: "xy", kind: "a", embedding: [0.7, 0.7, 0]),
        ])
        let nearest = try await docs.findNearest("embedding", vector: [1, 0.1, 0], topK: 2)
        XCTAssertEqual(nearest.map(\.document.title), ["x", "xy"])

        let onlyB = try await docs.findNearest("embedding", vector: [1, 0, 0], topK: 3, filter: ["kind": "b"])
        XCTAssertEqual(onlyB.map(\.document.title), ["y"])

        await assertThrowsAsync(try await docs.findNearest("embedding", vector: [1, 0], topK: 1), isEngineError)
    }

    func testHybridSearchFusesTextAndVectorRankings() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let docs = db.collection("docs", as: Doc.self)
        try await docs.createFtsIndex("text")
        try await docs.createVectorIndex("embedding", dimensions: 2)
        try await docs.insertMany([
            Doc(title: "both", text: "local first database", embedding: [1, 0]),
            Doc(title: "text", text: "local first sync", embedding: [0, 1]),
            Doc(title: "vector", text: "unrelated words", embedding: [0.9, 0.1]),
        ])
        let hits = try await docs.hybridSearch(
            textField: "text", text: "local database", vectorField: "embedding", vector: [1, 0], topK: 3
        )
        XCTAssertEqual(hits.first?.document.title, "both")
        XCTAssertEqual(hits.first?.textRank, 0)
        XCTAssertEqual(hits.first?.vectorRank, 0)
    }

    func testUserVersionAndCollectionNames() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let initial = try await db.userVersion()
        XCTAssertEqual(initial, 0)
        try await db.setUserVersion(7)
        let version = try await db.userVersion()
        XCTAssertEqual(version, 7)
        try await db.collection("alpha", as: Note.self).insert(Note(title: "a"))
        let names = try await db.collectionNames()
        XCTAssertEqual(names, ["alpha"])
    }

    func testAnEncryptedDatabaseNeedsItsPassphrase() async throws {
        let url = file("secret.db")
        let db = try await TalaDB.open(at: url, config: TalaDBConfig(passphrase: "correct horse"))
        try await db.collection("notes", as: Note.self).insert(Note(title: "hidden"))
        db.close()

        await assertThrowsAsync(try await TalaDB.open(at: url, config: TalaDBConfig(passphrase: "battery staple")), isEngineError)

        let reopened = try await TalaDB.open(at: url, config: TalaDBConfig(passphrase: "correct horse"))
        defer { reopened.close() }
        let note = try await reopened.collection("notes", as: Note.self).findOne()
        XCTAssertEqual(note?.title, "hidden")
    }

    func testConfigNeverPrintsItsPassphrase() {
        XCTAssertFalse(TalaDBConfig(passphrase: "hunter2").description.contains("hunter2"))
    }

    func testAClosedDatabaseRejectsCallsAndCloseIsIdempotent() async throws {
        let db = try await TalaDB.open(at: file())
        db.close()
        db.close()
        XCTAssertTrue(db.isClosed)
        await assertThrowsAsync(try await db.collection("notes").count()) { ($0 as? TalaDBError) == .closed }
    }

    func testOneDatabaseServesManyConcurrentTasks() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        let notes = db.collection("notes", as: Note.self)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<50 { try await notes.insert(Note(title: "w\(worker)-\(i)", stars: worker)) }
                }
            }
            try await group.waitForAll()
        }
        let count = try await notes.count()
        XCTAssertEqual(count, 400)
    }

    /// Each operation either completes or throws `.closed`; the process survives.
    func testCloseDuringConcurrentOperationsIsSafe() async throws {
        let db = try await TalaDB.open(at: file())
        let notes = db.collection("notes", as: Note.self)
        let results = await withTaskGroup(of: Error?.self) { group -> [Error?] in
            for i in 0..<32 {
                group.addTask {
                    do { try await notes.insert(Note(title: "n\(i)")); return nil } catch { return error }
                }
            }
            db.close()
            return await group.reduce(into: []) { $0.append($1) }
        }
        for case let error? in results {
            XCTAssertEqual(error as? TalaDBError, .closed)
        }
    }
}
