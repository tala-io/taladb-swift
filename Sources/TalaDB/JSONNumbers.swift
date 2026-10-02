import Foundation

// JSONDecoder accepts 1.0 as Int64. Supply the lexical number types to any
// JSONValue nested in a Codable model, without changing Foundation decoding
// of the model's ordinary Int, Float, Double, Date, Data or URL properties.
let jsonNumberKindsKey = CodingUserInfoKey(rawValue: "dev.taladb.jsonNumberKinds")!

func jsonNumberKinds(in text: String) throws -> [[String]: Bool] {
    var scanner = JSONNumberScanner(bytes: Array(text.utf8))
    try scanner.value(path: [], depth: 0)
    scanner.whitespace()
    guard scanner.index == scanner.bytes.count else { throw scanner.invalid() }
    return scanner.kinds
}

private struct JSONNumberScanner {
    let bytes: [UInt8]
    var index = 0
    var kinds: [[String]: Bool] = [:]
    var next: UInt8? { index < bytes.count ? bytes[index] : nil }

    func invalid() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "invalid JSON near byte \(index)"))
    }

    mutating func whitespace() {
        while let byte = next, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
    }

    mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard next == byte else { throw invalid() }
        index += 1
    }

    mutating func string() throws -> String {
        whitespace()
        let start = index
        try consume(34)
        while let byte = next {
            index += 1
            if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            if byte == 92 {
                guard next != nil else { throw invalid() }
                index += 1
            }
        }
        throw invalid()
    }

    mutating func value(path: [String], depth: Int) throws {
        guard depth <= 128 else { throw invalid() }
        whitespace()
        guard let byte = next else { throw invalid() }
        switch byte {
        case 123: // object
            index += 1
            whitespace()
            if next != 125 {
                while true {
                    let key = try string()
                    try consume(58)
                    try value(path: path + [key], depth: depth + 1)
                    whitespace()
                    if next != 44 { break }
                    index += 1
                }
            }
            try consume(125)
        case 91: // array
            index += 1
            whitespace()
            var element = 0
            if next != 93 {
                while true {
                    try value(path: path + ["Index \(element)"], depth: depth + 1)
                    element += 1
                    whitespace()
                    if next != 44 { break }
                    index += 1
                }
            }
            try consume(93)
        case 34: _ = try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57:
            let start = index
            var floating = false
            while let byte = next, byte == 45 || byte == 43 || byte == 46 || byte == 101 || byte == 69 || (48...57).contains(byte) {
                if byte == 46 || byte == 101 || byte == 69 { floating = true }
                index += 1
            }
            guard index > start else { throw invalid() }
            kinds[path] = floating
        default: throw invalid()
        }
    }

    mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard next == byte else { throw invalid() }
            index += 1
        }
    }
}
