import Foundation
import TalaDBFFI

/// A named set of documents in a ``TalaDB`` database, decoded as `Document`.
///
/// Filters, updates and pipelines use TalaDB's MongoDB-style operators, written
/// as ``JSONValue`` literals: `["age": ["$gte": 18]]`, `["$set": ["active": true]]`.
///
/// Every stored document has a string `_id`. A model that wants it declares an
/// optional property mapped to `_id`; leave it nil on insert and the engine
/// assigns one. A supplied `_id` must be a ULID, and inserting one that already
/// exists fails rather than overwriting.
///
/// ```swift
/// struct Note: Codable, Sendable {
///     var id: String?
///     var title: String
///     enum CodingKeys: String, CodingKey { case id = "_id", title }
/// }
/// ```
public struct TalaCollection<Document: Codable & Sendable>: Sendable {
    public let database: TalaDB
    public let name: String

    // MARK: - Documents

    /// Insert `document` and return its `_id`.
    @discardableResult
    public func insert(_ document: Document) async throws -> String {
        try await call("insert", [try Self.encodeDocument(document)], as: String.self)
    }

    /// Insert `documents` in one transaction and return their ids in the same
    /// order. All or nothing: if any document is rejected, none are written.
    @discardableResult
    public func insertMany(_ documents: [Document]) async throws -> [String] {
        try await call("insertMany", [jsonArray(try documents.map(Self.encodeDocument))], as: [String].self)
    }

    /// Every document matching `filter`.
    public func find(_ filter: Filter = [:]) async throws -> [Document] {
        try await call("find", [try jsonText(filter)], as: [Document].self)
    }

    /// The first document matching `filter`, or nil.
    public func findOne(_ filter: Filter = [:]) async throws -> Document? {
        try await call("findOne", [try jsonText(filter)], as: Document?.self)
    }

    /// How many documents match `filter`.
    public func count(_ filter: Filter = [:]) async throws -> Int {
        try await call("count", [try jsonText(filter)], as: Int.self)
    }

    /// Apply `update` to the first document matching `filter`. Returns whether one matched.
    @discardableResult
    public func updateOne(_ filter: Filter, _ update: Update) async throws -> Bool {
        try await call("updateOne", [try jsonText(filter), try jsonText(update)], as: Bool.self)
    }

    /// Apply `update` to every document matching `filter`. Returns how many were updated.
    @discardableResult
    public func updateMany(_ filter: Filter, _ update: Update) async throws -> Int {
        try await call("updateMany", [try jsonText(filter), try jsonText(update)], as: Int.self)
    }

    /// Delete the first document matching `filter`. Returns whether one matched.
    @discardableResult
    public func deleteOne(_ filter: Filter) async throws -> Bool {
        try await call("deleteOne", [try jsonText(filter)], as: Bool.self)
    }

    /// Delete every document matching `filter`; `[:]` empties the collection.
    /// Returns how many were deleted.
    @discardableResult
    public func deleteMany(_ filter: Filter) async throws -> Int {
        try await call("deleteMany", [try jsonText(filter)], as: Int.self)
    }

    /// Run an aggregation pipeline of `$match`, `$group`, `$sort`, `$skip`,
    /// `$limit` and `$project` stages. Results are raw JSON because their shape
    /// is set by the pipeline, not by `Document`.
    public func aggregate(_ pipeline: [JSONValue]) async throws -> [JSONValue] {
        try await call("aggregate", [try jsonText(pipeline)], as: [JSONValue].self)
    }

    // MARK: - Live queries

    /// The documents matching `filter`, now and after every write that changes
    /// them.
    ///
    /// Yields the current result first, then a fresh result whenever a write —
    /// through any handle on this database — changes it. Rapid writes coalesce
    /// into one element of the latest state; nothing is skipped.
    ///
    /// Each iteration opens its own native subscription, which closes when the
    /// iterating task is cancelled or the loop exits. Closing the database ends
    /// the stream by throwing `TalaDBError.closed`.
    ///
    /// ```swift
    /// for try await open in notes.watch(["done": false]) {
    ///     render(open)
    /// }
    /// ```
    public func watch(_ filter: Filter = [:]) -> AsyncThrowingStream<[Document], Error> {
        let database = database
        let name = name
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let filterJSON = try jsonText(filter)
                    // Subscribe before reading the initial state, so a write
                    // that lands between the two still wakes the loop below.
                    let watch = try await database.watchOpen(collection: name, filter: filterJSON)
                    defer { database.watchClose(watch) }
                    var last = try await database.call("find", [jsonText(name), filterJSON], as: JSONValue.self)
                    continuation.yield(try Self.decode([Document].self, last))
                    while !Task.isCancelled {
                        guard let text = try await database.watchNext(watch, timeoutMs: Self.watchPollMs) else {
                            continue
                        }
                        let snapshot = try decodeJSON(JSONValue.self, from: text)
                        if snapshot != last {
                            last = snapshot
                            continuation.yield(try Self.decode([Document].self, snapshot))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// How long one native wait for a live-query write lasts; bounds how
    /// quickly a cancelled stream releases its subscription.
    static var watchPollMs: UInt32 { 250 }

    // MARK: - Indexes

    /// Index `field` for equality and range filters. A no-op if it exists.
    public func createIndex(_ field: String) async throws {
        _ = try await call("createIndex", [try jsonText(field)], as: JSONValue.self)
    }

    /// Throws if there is no index on `field`.
    public func dropIndex(_ field: String) async throws {
        _ = try await call("dropIndex", [try jsonText(field)], as: JSONValue.self)
    }

    /// Index `fields` together, in order, for filters and sorts that use them jointly.
    public func createCompoundIndex(_ fields: [String]) async throws {
        _ = try await call("createCompoundIndex", [try jsonText(fields)], as: JSONValue.self)
    }

    public func dropCompoundIndex(_ fields: [String]) async throws {
        _ = try await call("dropCompoundIndex", [try jsonText(fields)], as: JSONValue.self)
    }

    /// Index `field` for ``searchText(_:query:topK:filter:options:)`` and the
    /// `$contains` filter. A no-op if it exists.
    public func createFtsIndex(_ field: String) async throws {
        _ = try await call("createFtsIndex", [try jsonText(field)], as: JSONValue.self)
    }

    /// Throws if there is no full-text index on `field`.
    public func dropFtsIndex(_ field: String) async throws {
        _ = try await call("dropFtsIndex", [try jsonText(field)], as: JSONValue.self)
    }

    /// The fields indexed on this collection, by index kind.
    public func listIndexes() async throws -> IndexInfo {
        try await call("listIndexes", [], as: IndexInfo.self)
    }

    // MARK: - Vectors

    /// Index the float-array `field` for vector search.
    ///
    /// Exact search (the default, `hnsw: nil`) is faster below tens of
    /// thousands of vectors and always exact. Pass ``HnswOptions`` to build a
    /// persistent approximate graph instead.
    public func createVectorIndex(
        _ field: String,
        dimensions: Int,
        metric: VectorMetric = .cosine,
        hnsw: HnswOptions? = nil
    ) async throws {
        guard dimensions > 0 else { throw TalaDBError.invalidArgument("dimensions must be positive") }
        var options: [String: JSONValue] = ["metric": .string(metric.rawValue)]
        if let hnsw { options["hnsw"] = try JSONValue(hnsw) }
        let args = [try jsonText(field), String(dimensions), try jsonText(JSONValue.object(options))]
        _ = try await call("createVectorIndex", args, as: JSONValue.self)
    }

    public func dropVectorIndex(_ field: String) async throws {
        _ = try await call("dropVectorIndex", [try jsonText(field)], as: JSONValue.self)
    }

    /// Promote a flat or legacy vector index, or compact its HNSW graph.
    public func upgradeVectorIndex(_ field: String) async throws {
        _ = try await call("upgradeVectorIndex", [try jsonText(field)], as: JSONValue.self)
    }

    /// The `topK` documents whose `field` is most similar to `vector`, best
    /// first. `filter` narrows the candidates before ranking.
    public func findNearest(
        _ field: String,
        vector: [Float],
        topK: Int,
        filter: Filter? = nil
    ) async throws -> [ScoredDocument<Document>] {
        guard topK >= 0 else { throw TalaDBError.invalidArgument("topK must not be negative") }
        let name = name
        return try await database.run { handle in
            let filterJSON = try filter.map { try jsonText($0) }
            let result = try withCStrings([name, field, filterJSON]) { p in
                vector.withUnsafeBufferPointer { v in
                    taladb_find_nearest(handle, p[0], p[1], v.baseAddress, UInt(v.count), UInt(topK), p[2])
                }
            }
            return try decodeJSON([ScoredDocument<Document>].self, from: try takeString(result, "findNearest failed"))
        }
    }

    // MARK: - Full-text

    /// The `topK` documents whose full-text-indexed `field` best matches
    /// `query`, ranked by BM25 with OR semantics. Requires ``createFtsIndex(_:)``.
    public func searchText(
        _ field: String,
        query: String,
        topK: Int,
        filter: Filter? = nil,
        options: Bm25Options = Bm25Options()
    ) async throws -> [ScoredDocument<Document>] {
        guard topK >= 0 else { throw TalaDBError.invalidArgument("topK must not be negative") }
        let args = [
            try jsonText(field), try jsonText(query), String(topK),
            try jsonText(filter.map(JSONValue.object) ?? .null), try jsonText(options.json),
        ]
        return try await call("searchText", args, as: [ScoredDocument<Document>].self)
    }

    /// Rank by both text relevance and vector similarity, fused with
    /// reciprocal rank fusion — for queries where exact terms and meaning both
    /// matter, such as retrieval for on-device RAG.
    public func hybridSearch(
        textField: String,
        text: String,
        vectorField: String,
        vector: [Float],
        topK: Int,
        filter: Filter? = nil,
        options: HybridOptions = HybridOptions()
    ) async throws -> [HybridHit<Document>] {
        guard topK >= 0 else { throw TalaDBError.invalidArgument("topK must not be negative") }
        let name = name
        return try await database.run { handle in
            let filterJSON = try filter.map { try jsonText($0) }
            let optionsJSON = try jsonText(options.json)
            let result = try withCStrings([name, textField, text, vectorField, filterJSON, optionsJSON]) { p in
                vector.withUnsafeBufferPointer { v in
                    taladb_hybrid_search(
                        handle, p[0], p[1], p[2], p[3], v.baseAddress, UInt(v.count), UInt(topK), p[4], p[5])
                }
            }
            return try decodeJSON([HybridHit<Document>].self, from: try takeString(result, "hybridSearch failed"))
        }
    }

    // MARK: - Plumbing

    /// A dispatch-table call whose first argument is this collection's name.
    func call<R: Decodable & Sendable>(
        _ op: String,
        _ args: @autoclosure @escaping @Sendable () throws -> [String],
        as type: R.Type
    ) async throws -> R {
        let name = name
        return try await database.call(op, [try jsonText(name)] + (try args()), as: type)
    }

    static func encodeDocument(_ document: Document) throws -> String {
        let text = try jsonText(document)
        guard text.first == "{" else {
            throw TalaDBError.invalidArgument(
                "TalaDB documents must encode to a JSON object; \(Document.self) does not")
        }
        return text
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try decodeJSON(type, from: try jsonText(value))
    }
}

extension JSONValue {
    /// Convert any encodable value to a JSONValue.
    init<T: Encodable>(_ value: T) throws {
        self = try decodeJSON(JSONValue.self, from: try jsonText(value))
    }
}
