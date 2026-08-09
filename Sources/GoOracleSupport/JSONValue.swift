//===----------------------------------------------------------------------===//
// A decoded JSON value, so a fixture carrying a whole tree can be compared
// structurally rather than as text.
//
// Lives here rather than in a test target because two suites need it —
// `promql/parse` compares upstream's `translate_ast.go` serialisation, and
// `promql/preprocess` compares the preprocessed tree — and a second copy of a JSON
// decoder is exactly the kind of thing that drifts.
//===----------------------------------------------------------------------===//

/// Numbers decode as `Int64`. Every number in these serialisations is an integer:
/// millisecond durations, timestamps, `variadic`. A fractional number fails to
/// decode, which is the right outcome — it means the shape changed. Floats travel
/// as hex bit-pattern strings instead (ADR-4's neighbourhood).
public enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }
}
