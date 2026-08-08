//===----------------------------------------------------------------------===//
// Ported from model/labels/matcher.go @ v3.13.2
//
// Regex matching now goes through PromRegex — a real RE2: an NFA simulation that
// is linear in (pattern x input) with no backtracking. See ADR-6.
//===----------------------------------------------------------------------===//

private import GoCompat
public import PromRegex

/// Go: `labels.MatchType`.
public enum MatchType: Int, Sendable, CaseIterable, CustomStringConvertible {
    case equal = 0
    case notEqual
    case regexp
    case notRegexp

    /// Go: `MatchType.String()`.
    public var description: String {
        switch self {
        case .equal: return "="
        case .notEqual: return "!="
        case .regexp: return "=~"
        case .notRegexp: return "!~"
        }
    }
}

/// The seam Phase 2's RE2 engine plugs into.
///
/// ⚠️ `setMatches` is not merely an optimisation: TSDB uses it to turn a regex
/// matcher into direct index lookups. It must be correct before Phase 6.
public protocol RegexMatching: Sendable {
    /// Go: `FastRegexMatcher.GetRegexString()`.
    var regexString: String { get }
    /// Go: `FastRegexMatcher.MatchString(s)`. Fully anchored.
    func matchString(_ s: String) -> Bool
    /// Go: `FastRegexMatcher.SetMatches()`. Empty when it cannot be reduced to a
    /// finite set of equality matches.
    var setMatches: [String] { get }
    /// Go: `FastRegexMatcher.prefix`.
    var prefix: String { get }
    /// Go: `FastRegexMatcher.IsOptimized()`.
    var isOptimized: Bool { get }
}

/// Builds the matcher used for `=~` / `!~`.
///
/// Injected rather than held in a mutable global: global mutable state is not
/// concurrency-safe under Swift 6.
public typealias RegexFactory = @Sendable (String) throws -> any RegexMatching

/// Backed by `PromRegex.FastRegexMatcher`, which mirrors Go: parse with
/// `Perl|DotNL`, render through `String()`, re-parse anchored as
/// `^(?s:...)$`, simplify, compile, then run an NFA.
public let defaultRegexFactory: RegexFactory = { try FastRegexMatcher($0) }

extension FastRegexMatcher: RegexMatching {
    // `regexString`, `matchString`, `setMatches`, `prefix` and `isOptimized` are
    // already the protocol's shape.
}

/// Go: `labels.Matcher`.
public struct Matcher: Sendable, CustomStringConvertible {

    public let type: MatchType
    public let name: String
    public let value: String
    private let re: (any RegexMatching)?

    /// Go: `labels.NewMatcher(t, n, v)`.
    public init(
        _ type: MatchType, _ name: String, _ value: String,
        regexFactory: RegexFactory = defaultRegexFactory
    ) throws {
        self.type = type
        self.name = name
        self.value = value
        if type == .regexp || type == .notRegexp {
            self.re = try regexFactory(value)
        } else {
            self.re = nil
        }
    }

    /// Go: `Matcher.Matches(s)`.
    public func matches(_ s: String) -> Bool {
        switch type {
        case .equal: return s == value
        case .notEqual: return s != value
        case .regexp: return re?.matchString(s) ?? false
        case .notRegexp: return !(re?.matchString(s) ?? false)
        }
    }

    /// Go: `Matcher.String()`.
    public var description: String {
        var out = ""
        out += shouldQuoteName ? GoStrconv.quote(name) : name
        out += type.description
        out += GoStrconv.quote(value)
        return out
    }

    /// Go: `Matcher.shouldQuoteName()`.
    ///
    /// Ported separately from `ValidationScheme.isValidLabelName` even though the
    /// two agree, because Go keeps them separate and they could drift. Note Go
    /// iterates runes with a *byte* index, so any non-ASCII rune fails the
    /// character classes and forces quoting; an empty name is also quoted.
    var shouldQuoteName: Bool {
        if name.isEmpty { return true }
        for (i, c) in name.utf8.enumerated() {
            let ok =
                c == UInt8(ascii: "_")
                || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
                || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
                || (i > 0 && c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
            if !ok { return true }
        }
        return false
    }

    /// Go: `Matcher.Inverse()`.
    public func inverse() throws -> Matcher {
        switch type {
        case .equal: return try Matcher(.notEqual, name, value)
        case .notEqual: return try Matcher(.equal, name, value)
        case .regexp: return try Matcher(.notRegexp, name, value)
        case .notRegexp: return try Matcher(.regexp, name, value)
        }
    }

    /// Go: `Matcher.GetRegexString()`.
    public var regexString: String { re?.regexString ?? "" }
    /// Go: `Matcher.SetMatches()`.
    public var setMatches: [String] { re?.setMatches ?? [] }
    /// Go: `Matcher.Prefix()`.
    public var prefix: String { re?.prefix ?? "" }
    /// Go: `Matcher.IsRegexOptimized()`.
    public var isRegexOptimized: Bool { re?.isOptimized ?? false }
}
