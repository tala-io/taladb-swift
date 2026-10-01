import Foundation
import TalaDBFFI

// Helpers for calling the C interface in taladb.h.
//
// Errors: `taladb_last_error()` is thread-local and describes the most recent
// call on the calling thread, so it is read by `engineError` immediately after
// the failing call, in the same synchronous block — never across an `await`,
// where the task could resume on another thread and read that thread's slot.

/// The error the engine reported for the call that just failed on this thread.
func engineError(_ fallback: String) -> TalaDBError {
    guard let message = taladb_last_error() else { return .engine(fallback) }
    return .engine(String(cString: message))
}

/// Copy an engine-owned result string into a Swift string and free it. A NULL
/// result is the engine reporting an error.
func takeString(_ result: UnsafeMutablePointer<CChar>?, _ fallback: String) throws -> String {
    guard let result else { throw engineError(fallback) }
    defer { taladb_free_string(result) }
    return String(cString: result)
}

/// Run `body` with each string as a NUL-terminated UTF-8 C string, or NULL
/// where the string is nil.
///
/// A string containing U+0000 is rejected: C would see it end at the first
/// NUL, so "a\u{0}b" would silently become "a". JSON text never contains a raw
/// NUL — the encoder escapes it — so this only constrains names and search text.
func withCStrings<R>(
    _ strings: [String?],
    _ body: ([UnsafePointer<CChar>?]) throws -> R
) throws -> R {
    for case let s? in strings where s.utf8.contains(0) {
        throw TalaDBError.invalidArgument("TalaDB strings must not contain U+0000")
    }
    func go(_ index: Int, _ pointers: [UnsafePointer<CChar>?]) throws -> R {
        if index == strings.count { return try body(pointers) }
        guard let s = strings[index] else { return try go(index + 1, pointers + [nil]) }
        return try s.withCString { try go(index + 1, pointers + [$0]) }
    }
    return try go(0, [])
}

// MARK: - JSON plumbing

/// Encode `value` as JSON text for the engine.
func jsonText<T: Encodable>(_ value: T) throws -> String {
    let data: Data
    do {
        data = try JSONEncoder().encode(value)
    } catch {
        throw TalaDBError.invalidArgument("value cannot be encoded as JSON: \(error)")
    }
    return String(decoding: data, as: UTF8.self)
}

/// Decode the engine's JSON result.
func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    } catch {
        throw TalaDBError.decoding("\(error)")
    }
}

/// A JSON array literal built from already-encoded JSON texts.
func jsonArray(_ elements: [String]) -> String {
    "[" + elements.joined(separator: ",") + "]"
}
