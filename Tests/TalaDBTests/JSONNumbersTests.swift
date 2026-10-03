import Foundation
import TalaDBFFI
import XCTest

@testable import TalaDB

final class JSONNumbersTests: DatabaseTestCase {
    func testIntegralFloatsAndLargeIntegersKeepTheirTypes() throws {
        let input: JSONValue = [
            "integer": .int(9_007_199_254_740_993),
            "max": .int(Int64.max), "min": .int(Int64.min),
            "float": .double(1.0), "negativeZero": .double(-0.0),
            "nested": [1, 1.0, ["0": 2.0, "Index 0": 3.0]],
            "escaped\"🚀": ["value": 4.0],
        ]
        let output = try decodeJSON(JSONValue.self, from: jsonText(input))
        XCTAssertEqual(output, input)
        guard case .double(let zero) = output["negativeZero"] else { return XCTFail("lost floating-point type") }
        XCTAssertEqual(zero.sign, .minus)
    }

    func testExponentsAndDecimalTokensDecodeAsFloats() throws {
        let output = try decodeJSON([JSONValue].self, from: "[1,1.0,1e0,1E+0,-0.0]")
        XCTAssertEqual(output, [.int(1), .double(1), .double(1), .double(1), .double(-0.0)])
    }

    func testTypedNumbersAndNestedJSONValuesKeepTheirTypes() throws {
        struct Model: Codable, Equatable {
            let double: Double
            let float: Float
            let integers: [Int64]
            let values: [String: JSONValue]
        }
        let input = Model(double: 1, float: 2, integers: [Int64.max, Int64.min], values: ["0": 3.0])
        let text = try jsonText(input)
        let raw = try decodeJSON(JSONValue.self, from: text)
        XCTAssertEqual(raw["double"], .double(1))
        XCTAssertEqual(raw["float"], .double(2))
        XCTAssertEqual(try decodeJSON(Model.self, from: text), input)
    }

    func testFoundationValuesKeepTheirDefaultCodableRepresentations() throws {
        struct Model: Codable, Equatable {
            let date: Date
            let data: Data
            let url: URL
            let decimal: Decimal
        }
        let input = Model(
            date: Date(timeIntervalSinceReferenceDate: 1.5),
            data: Data([0, 255, 42]),
            url: URL(string: "https://example.com/a?q=🚀")!,
            decimal: Decimal(string: "1.25")!
        )
        let text = try jsonText(input)
        XCTAssertEqual(try decodeJSON(Model.self, from: text), input)
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? NSDictionary
        let actual = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        XCTAssertEqual(actual, expected)
    }

    func testRejectsNonFiniteNumbersAndInvalidJSON() throws {
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertThrowsError(try jsonText(JSONValue.double(value)))
            XCTAssertThrowsError(try jsonText([value]))
        }
        for text in ["[1,]", "{\"a\":}", "1.0 trailing", "[1e]", "\"unterminated"] {
            XCTAssertThrowsError(try decodeJSON(JSONValue.self, from: text))
        }
    }

    func testFiltersMatchFloatsWrittenThroughTheFFI() async throws {
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        // Models the 1.0 JSON token sent by Kotlin and Rust clients.
        _ = try await db.run { handle in
            let result = try withCStrings(["insert", "[\"numbers\",{\"value\":1.0}]"]) { p in
                taladb_call(handle, p[0], p[1])
            }
            return try takeString(result, "insert failed")
        }
        let numbers = db.collection("numbers")
        let found = try await numbers.find(["value": .double(1.0)])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?["value"], .double(1.0))
        let integerMatches = try await numbers.count(["value": .int(1)])
        XCTAssertEqual(integerMatches, 0)
    }

    func testTypedFloatingPointDocumentsAreStoredAsFloats() async throws {
        struct Model: Codable, Sendable {
            let double: Double
            let float: Float
        }
        let db = try await TalaDB.open(at: file())
        defer { db.close() }
        try await db.collection("numbers", as: Model.self).insert(Model(double: 1, float: 2))
        let doc = try await db.collection("numbers").findOne()
        XCTAssertEqual(doc?["double"], .double(1))
        XCTAssertEqual(doc?["float"], .double(2))
    }
}
