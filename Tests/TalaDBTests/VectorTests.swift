import Foundation
import XCTest
@testable import TalaDB

final class VectorTests: DatabaseTestCase {
    private var db: TalaDB!
    private var docs: TalaCollection<Doc>!

    /// 60 unit vectors 6 degrees apart around a circle, alternating kind "a" / "b".
    override func setUp() async throws {
        try setUpWithError()
        db = try await TalaDB.open(at: file("vectors.db"))
        docs = db.collection("docs", as: Doc.self)
        try await docs.createVectorIndex("embedding", dimensions: 2)
        try await docs.insertMany((0..<60).map { i in
            let angle = Double(i) * .pi / 30
            return Doc(title: "d\(i)", kind: i % 2 == 0 ? "a" : "b", embedding: [Float(cos(angle)), Float(sin(angle))])
        })
    }

    override func tearDown() async throws {
        db.close()
        try tearDownWithError()
    }

    func testExactSearchReportsHowItRanAndPaginates() async throws {
        let first = try await docs.searchVectors("embedding", vector: [1, 0], topK: 3, options: VectorQueryOptions(mode: .exact))
        XCTAssertEqual(first.execution.path, "exact")
        XCTAssertEqual(first.execution.reason, "requestedExact")
        XCTAssertEqual(first.hits.first?.document.title, "d0")

        let offset = try XCTUnwrap(first.nextOffset)
        let second = try await docs.searchVectors(
            "embedding", vector: [1, 0], topK: 3, options: VectorQueryOptions(mode: .exact, offset: offset)
        )
        XCTAssertTrue(Set(first.hits.map(\.document.title)).isDisjoint(with: second.hits.map(\.document.title)))
    }

    func testFindWithinReturnsEverythingAboveTheThreshold() async throws {
        // 0.96 sits between cos 12° (0.978) and cos 18° (0.951).
        let near = try await docs.findWithin("embedding", vector: [1, 0], scoreThreshold: 0.96)
        XCTAssertEqual(Set(near.hits.map(\.document.title)), ["d0", "d1", "d2", "d58", "d59"])
        XCTAssertNil(near.nextOffset)
    }

    func testAnnOnAFlatIndexIsAnEngineError() async throws {
        let status = try await docs.vectorIndexStatus("embedding")
        XCTAssertEqual(status.state, .flat)
        await assertThrowsAsync(
            try await docs.searchVectors("embedding", vector: [1, 0], topK: 1, options: VectorQueryOptions(mode: .ann)),
            isEngineError
        )
    }

    func testBatchedRebuildReportsProgressAndEnablesTheGraph() async throws {
        let steps = RunLog()
        let done = try await docs.rebuildVectorIndex("embedding", options: HnswOptions(m: 8, efConstruction: 32), batchSize: 16) {
            steps.add(UInt32($0.processed))
        }
        XCTAssertEqual(done.state, .ready)
        XCTAssertEqual(done.processed, 60)
        XCTAssertGreaterThanOrEqual(steps.take().count, 4)

        let status = try await docs.vectorIndexStatus("embedding")
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.options, HnswOptions(m: 8, efConstruction: 32))

        let hit = try await docs.searchVectors("embedding", vector: [1, 0], topK: 1)
        XCTAssertEqual(hit.execution.path, "hnsw")
        XCTAssertEqual(hit.hits.first?.document.title, "d0")

        let filtered = try await docs.searchVectors("embedding", vector: [1, 0], topK: 1, filter: ["kind": "b"])
        XCTAssertEqual(filtered.execution.path, "exact", "a filter keeps .auto on exact search")

        let recall = try await docs.measureVectorRecall("embedding", queries: [[0.3, 0.9], [-1, 0.1]], topK: 5)
        XCTAssertTrue((0...1).contains(recall.recallAtK))
        XCTAssertEqual(recall.queries, 2)
    }

    func testCancellingARebuildCancelsTheBuild() async throws {
        let docs = docs!
        let task = Task {
            try await docs.rebuildVectorIndex("embedding", options: HnswOptions(m: 8, efConstruction: 32), batchSize: 4) { _ in }
        }
        task.cancel()
        let result = await task.result
        if case .success = result { XCTFail("a cancelled rebuild must not succeed") }

        let status = try await docs.vectorIndexStatus("embedding")
        XCTAssertNotEqual(status.build?.state, .building, "no build left running")
    }
}
