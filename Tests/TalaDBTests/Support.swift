import Foundation
import XCTest
@testable import TalaDB

struct Note: Codable, Sendable, Equatable {
    var id: String?
    var title: String
    var body: String = ""
    var stars: Int = 0

    enum CodingKeys: String, CodingKey { case id = "_id", title, body, stars }
}

struct Doc: Codable, Sendable {
    var id: String?
    var title: String
    var text: String = ""
    var kind: String = ""
    var embedding: [Float] = []

    enum CodingKeys: String, CodingKey { case id = "_id", title, text, kind, embedding }
}

/// A fresh directory per test, removed afterwards.
class DatabaseTestCase: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("taladb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String = "test.db") -> URL { directory.appendingPathComponent(name) }
}

func assertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ check: (Error) -> Bool = { _ in true }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        XCTAssertTrue(check(error), "unexpected error: \(error)", file: file, line: line)
    }
}

func isEngineError(_ error: Error) -> Bool {
    if case TalaDBError.engine = error { return true }
    return false
}
