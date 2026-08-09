//===----------------------------------------------------------------------===//
// Ported from promql/parser/value.go and functions.go @ v3.13.2
//
// The function table itself is GENERATED, into Generated/PromQLFunctions.swift —
// around a hundred entries with argument types, variadic arity and experimental
// flags, which would be tedious and unverifiable to transcribe. The
// `promql/functions` fixture suite then checks the committed table against Go, so
// a stale regeneration cannot pass silently.
//===----------------------------------------------------------------------===//

/// Go: `ValueType` — the type a PromQL expression evaluates to.
///
/// Go declares this as a `string` type and the raw values reach users: they are
/// what `DocumentedType` falls through to, and what parse errors name.
public struct ValueType: RawRepresentable, Sendable, Hashable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let none = ValueType("none")
    public static let vector = ValueType("vector")
    public static let scalar = ValueType("scalar")
    public static let matrix = ValueType("matrix")
    public static let string = ValueType("string")
}

extension ValueType: CustomStringConvertible {
    public var description: String { rawValue }
}

extension ValueType {
    /// Go: `DocumentedType` — the user-facing terminology from the documentation.
    ///
    /// Only vector and matrix are renamed; everything else, including `none`, falls
    /// through to the raw value.
    public var documented: String {
        switch self {
        case .vector: return "instant vector"
        case .matrix: return "range vector"
        default: return rawValue
        }
    }
}

/// Go: `Function` — a function of the expression language, referenced by `Call`.
public struct Function: Sendable, Hashable {
    public var name: String
    public var argTypes: [ValueType]
    /// Go: `Variadic` — 0 means fixed arity, a negative value means unlimited
    /// trailing arguments, and a positive value means that many optional ones.
    public var variadic: Int
    public var returnType: ValueType
    /// Gated behind `EnableExperimentalFunctions`.
    public var experimental: Bool

    public init(
        name: String, argTypes: [ValueType], variadic: Int, returnType: ValueType,
        experimental: Bool
    ) {
        self.name = name
        self.argTypes = argTypes
        self.variadic = variadic
        self.returnType = returnType
        self.experimental = experimental
    }
}

/// Namespace for the generated function table.
public enum PromQLFunctions: Sendable {
    /// Go: `parser.Functions[name]`, which callers use to resolve a call.
    public static func lookup(_ name: String) -> Function? { all[name] }
}
