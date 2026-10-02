import Foundation

// Foundation's JSONEncoder writes integral floating-point values as integers.
// Build the Codable value tree first so the engine receives each number's type.
func encodeEngineJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = EngineJSONEncoder()
    try ValueContainer(encoder: encoder).encode(value)
    return try encoder.node.resolve().wireJSON()
}

private final class JSONNode {
    var value: JSONValue?
    var object: [String: JSONNode]?
    var array: [JSONNode]?

    func resolve() throws -> JSONValue {
        if let value { return value }
        if let object { return .object(try object.mapValues { try $0.resolve() }) }
        if let array { return .array(try array.map { try $0.resolve() }) }
        throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "value encoded no JSON"))
    }
}

private struct JSONIndexKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(index: Int) { stringValue = "Index \(index)"; intValue = index }
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.init(index: intValue) }
}

private struct EngineJSONEncoder: Encoder {
    let node: JSONNode
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(node: JSONNode = JSONNode(), codingPath: [CodingKey] = []) {
        self.node = node
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if node.object == nil { node.object = [:] }
        return KeyedEncodingContainer(ObjectContainer<Key>(encoder: self))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        if node.array == nil { node.array = [] }
        return ArrayContainer(encoder: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer { ValueContainer(encoder: self) }
}

private struct ValueContainer: SingleValueEncodingContainer {
    let encoder: EngineJSONEncoder
    var codingPath: [CodingKey] { encoder.codingPath }

    func encodeNil() throws { encoder.node.value = .null }

    func encode<T: Encodable>(_ value: T) throws {
        switch value {
        case let value as JSONValue: encoder.node.value = value
        case let value as Bool: encoder.node.value = .bool(value)
        case let value as String: encoder.node.value = .string(value)
        case let value as Double: encoder.node.value = .double(value)
        case let value as Float:
            encoder.node.value = .double(Double(String(value)) ?? Double(value))
        case let value as any BinaryInteger:
            encoder.node.value = Int64(exactly: value).map(JSONValue.int) ?? .double(Double(value))
        // Keep JSONEncoder's default Foundation representations.
        case let value as Date: encoder.node.value = .double(value.timeIntervalSinceReferenceDate)
        case let value as Data: encoder.node.value = .string(value.base64EncodedString())
        case let value as URL: encoder.node.value = .string(value.absoluteString)
        case let value as Decimal:
            let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            encoder.node.value = try decodeJSON(JSONValue.self, from: text)
        default: try value.encode(to: encoder)
        }
    }
}

private struct ObjectContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: EngineJSONEncoder
    var codingPath: [CodingKey] { encoder.codingPath }

    private func child(_ key: CodingKey) -> EngineJSONEncoder {
        let node = JSONNode()
        encoder.node.object?[key.stringValue] = node
        return EngineJSONEncoder(node: node, codingPath: codingPath + [key])
    }

    func encodeNil(forKey key: Key) throws { try ValueContainer(encoder: child(key)).encodeNil() }
    func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try ValueContainer(encoder: child(key)).encode(value)
    }
    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        child(key).container(keyedBy: type)
    }
    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { child(key).unkeyedContainer() }
    func superEncoder(forKey key: Key) -> Encoder { child(key) }
    func superEncoder() -> Encoder { child(JSONIndexKey(stringValue: "super")!) }
}

private struct ArrayContainer: UnkeyedEncodingContainer {
    let encoder: EngineJSONEncoder
    var codingPath: [CodingKey] { encoder.codingPath }
    var count: Int { encoder.node.array?.count ?? 0 }

    private func child() -> EngineJSONEncoder {
        let key = JSONIndexKey(index: count)
        let node = JSONNode()
        encoder.node.array?.append(node)
        return EngineJSONEncoder(node: node, codingPath: codingPath + [key])
    }

    func encodeNil() throws { try ValueContainer(encoder: child()).encodeNil() }
    func encode<T: Encodable>(_ value: T) throws { try ValueContainer(encoder: child()).encode(value) }
    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        child().container(keyedBy: type)
    }
    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { child().unkeyedContainer() }
    func superEncoder() -> Encoder { child() }
}

private extension JSONValue {
    func wireJSON() throws -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "JSON numbers must be finite"))
            }
            return String(value) // e.g. 1.0, rather than 1
        case .string(let value): return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        case .array(let values): return "[" + (try values.map { try $0.wireJSON() }).joined(separator: ",") + "]"
        case .object(let values):
            let fields = try values.keys.sorted().map { key in
                try JSONValue.string(key).wireJSON() + ":" + values[key]!.wireJSON()
            }
            return "{" + fields.joined(separator: ",") + "}"
        }
    }
}
