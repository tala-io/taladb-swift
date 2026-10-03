/// How ``TalaCollection/searchVectors(_:vector:topK:filter:options:)`` chooses
/// between exact scan and the HNSW graph.
public enum VectorSearchMode: String, Sendable, Codable {
    /// The graph when it is ready and there is no filter; otherwise exact.
    /// Filtered queries stay exact unless `.ann` is requested.
    case auto
    case exact
    /// Approximate; throws if the graph is missing or stale.
    case ann
}

/// Execution controls for vector search. `nil` keeps the engine default.
public struct VectorQueryOptions: Sendable, Equatable {
    public var mode: VectorSearchMode
    /// HNSW candidate list size: higher is slower and more exact.
    public var efSearch: Int?
    /// Drop hits scoring below this.
    public var scoreThreshold: Float?
    /// Skip this many hits, for pagination. Pages come from live data, so
    /// writes between pages can shift results.
    public var offset: Int
    /// Keep only the best `groupSize` hits per distinct value of this field.
    public var groupBy: String?
    public var groupSize: Int?
    /// ANN candidates fetched per result before exact rescoring (1–100).
    public var oversampling: Int?

    public init(
        mode: VectorSearchMode = .auto,
        efSearch: Int? = nil,
        scoreThreshold: Float? = nil,
        offset: Int = 0,
        groupBy: String? = nil,
        groupSize: Int? = nil,
        oversampling: Int? = nil
    ) {
        self.mode = mode
        self.efSearch = efSearch
        self.scoreThreshold = scoreThreshold
        self.offset = offset
        self.groupBy = groupBy
        self.groupSize = groupSize
        self.oversampling = oversampling
    }

    // The engine rejects unknown keys, so only set fields are sent.
    var json: JSONValue {
        var o: [String: JSONValue] = ["mode": .string(mode.rawValue)]
        if let efSearch { o["efSearch"] = .int(Int64(efSearch)) }
        if let scoreThreshold { o["scoreThreshold"] = .double(Double(scoreThreshold)) }
        if offset != 0 { o["offset"] = .int(Int64(offset)) }
        if let groupBy { o["groupBy"] = .string(groupBy) }
        if let groupSize { o["groupSize"] = .int(Int64(groupSize)) }
        if let oversampling { o["oversampling"] = .int(Int64(oversampling)) }
        return .object(o)
    }
}

/// The hits of a vector search and how it ran.
public struct VectorQueryResult<Document: Decodable & Sendable>: Decodable, Sendable {
    public let hits: [ScoredDocument<Document>]
    public let execution: VectorExecution
    /// Pass as ``VectorQueryOptions/offset`` for the next page; nil on the last.
    public let nextOffset: Int?
}

/// How a vector query executed.
public struct VectorExecution: Decodable, Sendable, Equatable {
    /// `"exact"` or `"hnsw"`.
    public let path: String
    /// Why that path was chosen.
    public let reason: String
    public let revision: UInt64
    public let efSearch: Int?
    public let distanceComputations: UInt64
}

public enum VectorBuildState: String, Sendable, Decodable {
    case building, ready, cancelled, failed
}

/// Progress of a batched HNSW build.
public struct VectorBuildProgress: Decodable, Sendable, Equatable {
    public let id: String
    public let state: VectorBuildState
    public let processed: UInt64
    public let total: UInt64
    public let revision: UInt64
    public let error: String?
}

public enum VectorIndexState: String, Sendable, Decodable {
    /// Exact search only; no graph.
    case flat
    /// The graph covers every vector.
    case ready
    /// The graph is behind the stored vectors; `.auto` uses exact scan until it is rebuilt.
    case stale
    /// A legacy-format index from an older engine; rebuild it to get a graph.
    case rebuildRequired
}

/// The state of one vector index.
public struct VectorIndexStatus: Decodable, Sendable, Equatable {
    public let field: String
    public let state: VectorIndexState
    public let persistent: Bool
    public let indexedVectors: UInt64
    public let totalVectors: UInt64
    public let deletedNodes: UInt64
    public let revision: UInt64
    public let indexRevision: UInt64?
    public let options: HnswOptions?
    public let build: VectorBuildProgress?
}

/// Approximate-search quality against exact ground truth.
public struct VectorRecall: Decodable, Sendable, Equatable {
    /// Mean fraction of the exact top-k that approximate search also returned.
    public let recallAtK: Double
    public let queries: Int
    public let topK: Int
    public let exactMs: Double
    public let annMs: Double
}

extension TalaCollection {
    /// Vector search with execution control: exact or approximate mode,
    /// `efSearch`, a score threshold, offset pagination and grouping. Returns
    /// how the query ran alongside the hits.
    /// ``findNearest(_:vector:topK:filter:)`` covers the common case.
    public func searchVectors(
        _ field: String,
        vector: [Float],
        topK: Int,
        filter: Filter? = nil,
        options: VectorQueryOptions = VectorQueryOptions()
    ) async throws -> VectorQueryResult<Document> {
        guard topK >= 0 else { throw TalaDBError.invalidArgument("topK must not be negative") }
        var request: [String: JSONValue] = [
            "op": "search", "field": .string(field), "query": try Self.vectorJSON(vector),
            "topK": .int(Int64(topK)), "options": options.json,
        ]
        if let filter { request["filter"] = .object(filter) }
        return try await vectorCommand(request, as: VectorQueryResult<Document>.self)
    }

    /// Every document whose `field` scores at least `scoreThreshold` against
    /// `vector`, by exact search.
    public func findWithin(
        _ field: String,
        vector: [Float],
        scoreThreshold: Float,
        filter: Filter? = nil
    ) async throws -> VectorQueryResult<Document> {
        try await searchVectors(
            field, vector: vector, topK: Int(UInt32.max), filter: filter,
            options: VectorQueryOptions(mode: .exact, scoreThreshold: scoreThreshold)
        )
    }

    /// Whether `field`'s vector index is flat, ready, stale or needs a
    /// rebuild, and any build in progress.
    public func vectorIndexStatus(_ field: String) async throws -> VectorIndexStatus {
        try await vectorCommand(["op": "status", "field": .string(field)], as: VectorIndexStatus.self)
    }

    /// Build or rebuild `field`'s HNSW graph in batches of `batchSize`
    /// insertions, reporting progress after each. The index stays queryable
    /// throughout — searches use exact scan until the graph is ready.
    ///
    /// Cancelling the calling task cancels the build. Throws if the build fails.
    @discardableResult
    public func rebuildVectorIndex(
        _ field: String,
        options: HnswOptions? = nil,
        batchSize: Int = 32,
        onProgress: @Sendable (VectorBuildProgress) -> Void = { _ in }
    ) async throws -> VectorBuildProgress {
        guard (1...1024).contains(batchSize) else { throw TalaDBError.invalidArgument("batchSize must be in 1...1024") }
        var progress = try await beginVectorBuild(field, options: options)
        do {
            onProgress(progress)
            while progress.state == .building {
                try Task.checkCancellation()
                progress = try await stepVectorBuild(field, id: progress.id, batchSize: batchSize)
                onProgress(progress)
            }
        } catch {
            if progress.state == .building {
                _ = try? await cancelVectorBuild(field, id: progress.id)
            }
            throw error
        }
        if progress.state == .failed { throw TalaDBError.engine(progress.error ?? "vector index rebuild failed") }
        return progress
    }

    /// Start a batched HNSW build; drive it with ``stepVectorBuild(_:id:batchSize:)``.
    /// ``rebuildVectorIndex(_:options:batchSize:onProgress:)`` does both.
    public func beginVectorBuild(_ field: String, options: HnswOptions? = nil) async throws -> VectorBuildProgress {
        var request: [String: JSONValue] = ["op": "beginBuild", "field": .string(field)]
        if let options { request["options"] = try JSONValue(options) }
        return try await vectorCommand(request, as: VectorBuildProgress.self)
    }

    /// Insert up to `batchSize` more vectors into the build `id`.
    public func stepVectorBuild(_ field: String, id: String, batchSize: Int = 32) async throws -> VectorBuildProgress {
        guard (1...1024).contains(batchSize) else { throw TalaDBError.invalidArgument("batchSize must be in 1...1024") }
        return try await vectorCommand(
            ["op": "stepBuild", "field": .string(field), "id": .string(id), "batchSize": .int(Int64(batchSize))],
            as: VectorBuildProgress.self
        )
    }

    @discardableResult
    public func cancelVectorBuild(_ field: String, id: String) async throws -> VectorBuildProgress {
        try await vectorCommand(
            ["op": "cancelBuild", "field": .string(field), "id": .string(id)], as: VectorBuildProgress.self)
    }

    /// Measure how often approximate search finds the exact top `topK` for
    /// `queries` — use real query embeddings, not stored vectors — and how
    /// long each path takes. For tuning `efSearch` and graph options.
    public func measureVectorRecall(
        _ field: String,
        queries: [[Float]],
        topK: Int,
        filter: Filter? = nil,
        options: VectorQueryOptions = VectorQueryOptions()
    ) async throws -> VectorRecall {
        guard (1...1000).contains(queries.count) else {
            throw TalaDBError.invalidArgument("recall needs 1...1000 queries")
        }
        guard topK >= 1 else { throw TalaDBError.invalidArgument("topK must be positive") }
        var request: [String: JSONValue] = [
            "op": "recall", "field": .string(field), "queries": .array(try queries.map(Self.vectorJSON)),
            "topK": .int(Int64(topK)), "options": options.json,
        ]
        if let filter { request["filter"] = .object(filter) }
        return try await vectorCommand(request, as: VectorRecall.self)
    }

    private func vectorCommand<R: Decodable & Sendable>(_ request: [String: JSONValue], as type: R.Type) async throws
        -> R
    {
        try await call("vectorCommand", [try jsonText(JSONValue.object(request))], as: type)
    }

    static func vectorJSON(_ vector: [Float]) throws -> JSONValue {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
            throw TalaDBError.invalidArgument("vector must contain finite numbers")
        }
        return .array(vector.map { .double(Double($0)) })
    }
}
