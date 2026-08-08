//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/regexp/syntax/parse.go
//
// Prometheus parses label matchers with `syntax.Parse(v, syntax.Perl|syntax.DotNL)`
// (model/labels/regexp.go:69 @ v3.13.2), so this must accept and reject exactly
// what Go does, produce the same tree, and produce the same error strings.
//
// Structural notes:
//  - Go indexes the pattern by BYTE and builds error messages from byte spans
//    (`before[:len(before)-len(after)]`), so the cursor here is a byte index into
//    a [UInt8] and error spans are index pairs.
//  - Go's node pooling (`p.free`, `reuse`) exists only to reduce allocation; it is
//    dropped here. Nothing observable depends on it.
//===----------------------------------------------------------------------===//

private import GoCompat

/// Go: `syntax.ErrorCode`. The raw values are the user-visible message text.
public enum RegexErrorCode: String, Sendable {
    case internalError = "regexp/syntax: internal error"
    case invalidCharClass = "invalid character class"
    case invalidCharRange = "invalid character class range"
    case invalidEscape = "invalid escape sequence"
    case invalidNamedCapture = "invalid named capture"
    case invalidPerlOp = "invalid or unsupported Perl syntax"
    case invalidRepeatOp = "invalid nested repetition operator"
    case invalidRepeatSize = "invalid repeat count"
    case invalidUTF8 = "invalid UTF-8"
    case missingBracket = "missing closing ]"
    case missingParen = "missing closing )"
    case missingRepeatArgument = "missing argument to repetition operator"
    case trailingBackslash = "trailing backslash at end of expression"
    case unexpectedParen = "unexpected )"
    case nestingDepth = "expression nests too deeply"
    case large = "expression too large"
}

/// Go: `syntax.Error`. The `description` reproduces Go's `Error()` byte-for-byte,
/// because these strings surface to users through PromQL errors.
public struct RegexError: Error, Equatable, CustomStringConvertible {
    public let code: RegexErrorCode
    public let expr: String

    public init(_ code: RegexErrorCode, _ expr: String) {
        self.code = code
        self.expr = expr
    }

    public var description: String {
        "error parsing regexp: " + code.rawValue + ": `" + expr + "`"
    }
}

/// Go: `syntax.Parse`.
///
/// Note a Swift `String` cannot hold invalid UTF-8, so Go's `ErrInvalidUTF8` is
/// unreachable through this entry point. Use `parseRegex(bytes:)` when the input
/// may be arbitrary bytes — see docs/DECISIONS.md ADR-9.
public func parseRegex(_ pattern: String, _ flags: RegexFlags = .perl) throws -> Regexp {
    try parseRegex(bytes: Array(pattern.utf8), flags)
}

/// Go: `syntax.Parse` over raw bytes.
///
/// This is the primitive. Go's parser works on a `string`, which is an arbitrary
/// byte sequence, and it rejects invalid UTF-8 with a specific error; reproducing
/// that requires seeing the bytes.
public func parseRegex(bytes: [UInt8], _ flags: RegexFlags = .perl) throws -> Regexp {
    var p = RegexParser(bytes: bytes, flags: flags)
    return try p.parse()
}

/// Go: `syntax.parser`.
struct RegexParser {

    // Go: maxHeight / maxSize / maxRunes, with instSize = 5*8 and runeSize = 4.
    private static let maxHeight = 1000
    private static let maxSize: Int64 = (128 << 20) / (5 * 8)
    private static let maxRunes = (128 << 20) / 4
    private static let maxRune: UInt32 = 0x10FFFF

    var parseFlags: RegexFlags
    private var stack: [Regexp] = []
    private var numCap = 0
    let wholePattern: String
    let inputBytes: [UInt8]
    /// Go: `p.tmpClass` — scratch space for folded class construction.
    private var tmpClass: [UInt32] = []
    private var numRegexp = 0
    private var numRunes = 0
    private var repeats: Int64 = 0
    private var heights: [ObjectIdentifier: Int] = [:]
    private var sizes: [ObjectIdentifier: Int64] = [:]
    private var trackingHeight = false
    private var trackingSize = false

    init(bytes: [UInt8], flags: RegexFlags) {
        self.parseFlags = flags
        self.inputBytes = bytes
        // Used only in error messages; lossy decoding is fine there because Go
        // renders the same bytes back into its message text.
        self.wholePattern = String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Cursor helpers

    /// The pattern text from byte offset `from` up to (not including) `to`.
    func text(_ from: Int, _ to: Int) -> String {
        String(decoding: inputBytes[from..<to], as: UTF8.self)
    }

    func text(from: Int) -> String {
        String(decoding: inputBytes[from...], as: UTF8.self)
    }

    mutating func makeRegexp(_ op: RegexOp) -> Regexp {
        numRegexp += 1
        return Regexp(op: op)
    }

    // MARK: - Limits

    /// Go: `checkLimits`. Uses `throws` where Go panics and recovers in `parse`.
    private mutating func checkLimits(_ re: Regexp) throws {
        if numRunes > Self.maxRunes { throw RegexError(.large, wholePattern) }
        try checkSize(re)
        try checkHeight(re)
    }

    /// Go: `checkSize`.
    private mutating func checkSize(_ re: Regexp) throws {
        if !trackingSize {
            // Cheap pre-check: maintain the product of repeats seen and only start
            // tracking once the node count times that product leaves the budget.
            if repeats == 0 { repeats = 1 }
            if re.op == .repeat {
                var n = re.max
                if n == -1 { n = re.min }
                if n <= 0 { n = 1 }
                if Int64(n) > Self.maxSize / repeats {
                    repeats = Self.maxSize
                } else {
                    repeats *= Int64(n)
                }
            }
            if Int64(numRegexp) < Self.maxSize / repeats { return }

            trackingSize = true
            for s in stack { try checkSize(s) }
        }
        if calcSize(re, force: true) > Self.maxSize { throw RegexError(.large, wholePattern) }
    }

    /// Go: `calcSize`.
    private mutating func calcSize(_ re: Regexp, force: Bool) -> Int64 {
        if !force, let s = sizes[ObjectIdentifier(re)] { return s }
        var size: Int64 = 0
        switch re.op {
        case .literal:
            size = Int64(re.rune.count)
        case .capture, .star:
            // A star compiles to 1+ or 2+ instructions; assume 2 pessimistically.
            size = 2 + calcSize(re.sub[0], force: false)
        case .plus, .quest:
            size = 1 + calcSize(re.sub[0], force: false)
        case .concat:
            for s in re.sub { size += calcSize(s, force: false) }
        case .alternate:
            for s in re.sub { size += calcSize(s, force: false) }
            if re.sub.count > 1 { size += Int64(re.sub.count) - 1 }
        case .repeat:
            let sub = calcSize(re.sub[0], force: false)
            if re.max == -1 {
                size = re.min == 0 ? 2 + sub : 1 + Int64(re.min) * sub
            } else {
                // x{2,5} compiles as xx(x(x(x)?)?)?
                size = Int64(re.max) * sub + Int64(re.max - re.min)
            }
        default:
            break
        }
        size = Swift.max(1, size)
        sizes[ObjectIdentifier(re)] = size
        return size
    }

    /// Go: `checkHeight`.
    private mutating func checkHeight(_ re: Regexp) throws {
        if numRegexp < Self.maxHeight { return }
        if !trackingHeight {
            trackingHeight = true
            for s in stack { try checkHeight(s) }
        }
        if calcHeight(re, force: true) > Self.maxHeight {
            throw RegexError(.nestingDepth, wholePattern)
        }
    }

    /// Go: `calcHeight`.
    private mutating func calcHeight(_ re: Regexp, force: Bool) -> Int {
        if !force, let h = heights[ObjectIdentifier(re)] { return h }
        var h = 1
        for s in re.sub {
            h = Swift.max(h, 1 + calcHeight(s, force: false))
        }
        heights[ObjectIdentifier(re)] = h
        return h
    }

    // MARK: - Stack

    /// Go: `push`. Rewrites single-rune classes into literals so that incremental
    /// concatenation can fold them together.
    @discardableResult
    mutating func pushNode(_ re: Regexp) throws -> Regexp? {
        numRunes += re.rune.count

        if re.op == .charClass && re.rune.count == 2 && re.rune[0] == re.rune[1] {
            // Single rune.
            if maybeConcat(Int64(re.rune[0]), parseFlags.subtracting(.foldCase)) { return nil }
            re.op = .literal
            re.rune = [re.rune[0]]
            re.flags = parseFlags.subtracting(.foldCase)
        } else if isCaseInsensitiveRunePair(re) {
            // Case-insensitive rune like [Aa] or [Δδ]: rewrite as a folded literal.
            if maybeConcat(Int64(re.rune[0]), parseFlags.union(.foldCase)) { return nil }
            re.op = .literal
            re.rune = [re.rune[0]]
            re.flags = parseFlags.union(.foldCase)
        } else {
            maybeConcat(-1, [])
        }

        stack.append(re)
        try checkLimits(re)
        return re
    }

    /// The two shapes Go recognises as a case-insensitive rune pair.
    private func isCaseInsensitiveRunePair(_ re: Regexp) -> Bool {
        guard re.op == .charClass else { return false }
        if re.rune.count == 4,
            re.rune[0] == re.rune[1], re.rune[2] == re.rune[3],
            UnicodeTables.simpleFold(re.rune[0]) == re.rune[2],
            UnicodeTables.simpleFold(re.rune[2]) == re.rune[0]
        {
            return true
        }
        if re.rune.count == 2,
            re.rune[0] + 1 == re.rune[1],
            UnicodeTables.simpleFold(re.rune[0]) == re.rune[1],
            UnicodeTables.simpleFold(re.rune[1]) == re.rune[0]
        {
            return true
        }
        return false
    }

    /// Go: `maybeConcat`. Folds adjacent literals into one node.
    ///
    /// Called before each push, so only the top of the stack can need work — and
    /// because it runs *before* the push, the topmost literal is no longer subject
    /// to a following operator (otherwise `ab*` would become `(ab)*`).
    /// Returns whether `r` was consumed.
    @discardableResult
    private mutating func maybeConcat(_ r: Int64, _ newFlags: RegexFlags) -> Bool {
        let n = stack.count
        if n < 2 { return false }
        let re1 = stack[n - 1]
        let re2 = stack[n - 2]
        guard re1.op == .literal, re2.op == .literal,
            re1.flags.intersection(.foldCase) == re2.flags.intersection(.foldCase)
        else { return false }

        re2.rune.append(contentsOf: re1.rune)

        if r >= 0 {
            // Reuse the popped node to carry r.
            re1.rune = [UInt32(r)]
            re1.flags = newFlags
            return true
        }
        stack.removeLast()
        return false
    }

    /// Go: `literal`.
    private mutating func literal(_ r: UInt32) throws {
        let re = makeRegexp(.literal)
        re.flags = parseFlags
        re.rune = [parseFlags.contains(.foldCase) ? UnicodeTables.minFoldRune(r) : r]
        try pushNode(re)
    }

    /// Go: `op`.
    @discardableResult
    mutating func pushOp(_ op: RegexOp) throws -> Regexp? {
        let re = makeRegexp(op)
        re.flags = parseFlags
        return try pushNode(re)
    }

    // MARK: - Repetition

    /// Go: `repeat`. `beforeIdx`/`afterIdx` are byte offsets, used for error spans.
    private mutating func repeatOp(
        _ op: RegexOp, _ min: Int, _ max: Int,
        beforeIdx: Int, afterIdx: Int, lastRepeatIdx: Int?
    ) throws -> Int {
        var after = afterIdx
        var f = parseFlags
        if parseFlags.contains(.perlX) {
            if after < inputBytes.count, inputBytes[after] == UInt8(ascii: "?") {
                after += 1
                f.formSymmetricDifference(.nonGreedy)
            }
            if let lr = lastRepeatIdx {
                // Perl forbids stacking repetition operators: `a**` is an error,
                // and `a++` means something else entirely.
                throw RegexError(.invalidRepeatOp, text(lr, after))
            }
        }
        guard let sub = stack.last, !sub.op.isPseudo else {
            throw RegexError(.missingRepeatArgument, text(beforeIdx, after))
        }

        let re = makeRegexp(op)
        re.min = min
        re.max = max
        re.flags = f
        re.sub = [sub]
        stack[stack.count - 1] = re
        try checkLimits(re)

        if op == .repeat, min >= 2 || max >= 2, !Self.repeatIsValid(re, 1000) {
            throw RegexError(.invalidRepeatSize, text(beforeIdx, after))
        }
        return after
    }

    /// Go: `repeatIsValid` — the combination of nested repetitions must not exceed
    /// `n` copies of the innermost expression.
    private static func repeatIsValid(_ re: Regexp, _ n: Int) -> Bool {
        var n = n
        if re.op == .repeat {
            var m = re.max
            if m == 0 { return true }
            if m < 0 { m = re.min }
            if m > n { return false }
            if m > 0 { n /= m }
        }
        for s in re.sub where !repeatIsValid(s, n) { return false }
        return true
    }

    // MARK: - Concatenation and alternation

    /// Go: `concat`.
    @discardableResult
    private mutating func concat() throws -> Regexp? {
        maybeConcat(-1, [])

        // Scan down to the pseudo-operator `|` or `(`.
        var i = stack.count
        while i > 0 && !stack[i - 1].op.isPseudo { i -= 1 }
        let subs = Array(stack[i...])
        stack.removeSubrange(i...)

        if subs.isEmpty {
            return try pushNode(makeRegexp(.emptyMatch))
        }
        return try pushNode(collapse(subs, .concat))
    }

    /// Go: `alternate`.
    @discardableResult
    private mutating func alternate() throws -> Regexp? {
        // Scan down to `(`. There are no `|` above it.
        var i = stack.count
        while i > 0 && !stack[i - 1].op.isPseudo { i -= 1 }
        let subs = Array(stack[i...])
        stack.removeSubrange(i...)

        // The others were cleaned by swapVerticalBar.
        if let last = subs.last { Self.cleanAltNode(last) }

        if subs.isEmpty {
            return try pushNode(makeRegexp(.noMatch))
        }
        return try pushNode(collapse(subs, .alternate))
    }

    /// Go: `cleanAlt`.
    static func cleanAltNode(_ re: Regexp) {
        guard re.op == .charClass else { return }
        re.rune = cleanClass(&re.rune)
        if re.rune.count == 2, re.rune[0] == 0, re.rune[1] == maxRune {
            re.rune = []
            re.op = .anyChar
            return
        }
        if re.rune.count == 4, re.rune[0] == 0, re.rune[1] == 0x0A - 1,
            re.rune[2] == 0x0A + 1, re.rune[3] == maxRune
        {
            re.rune = []
            re.op = .anyCharNotNL
            return
        }
    }

    /// Go: `collapse` — hoists nested same-op nodes so there is never a concat of
    /// a concat, or an alternate of an alternate.
    mutating func collapse(_ subs: [Regexp], _ op: RegexOp) -> Regexp {
        if subs.count == 1 { return subs[0] }
        let re = makeRegexp(op)
        var out = [Regexp]()
        for sub in subs {
            if sub.op == op {
                out.append(contentsOf: sub.sub)
            } else {
                out.append(sub)
            }
        }
        re.sub = out
        if op == .alternate {
            re.sub = factor(re.sub)
            if re.sub.count == 1 { return re.sub[0] }
        }
        return re
    }

    // MARK: - parse

    /// Go: `parse`. The main dispatch loop.
    mutating func parse() throws -> Regexp {
        if parseFlags.contains(.literal) {
            // Trivial path for a literal pattern.
            try Self.checkUTF8(inputBytes, 0, wholePattern)
            return Self.literalRegexp(wholePattern, parseFlags)
        }

        var t = 0  // byte cursor
        var lastRepeat: Int? = nil

        while t < inputBytes.count {
            var repeatIdx: Int? = nil

            switch inputBytes[t] {
            case UInt8(ascii: "("):
                if parseFlags.contains(.perlX), t + 1 < inputBytes.count, inputBytes[t + 1] == UInt8(ascii: "?") {
                    t = try parsePerlFlags(t)
                    break
                }
                numCap += 1
                let re = try pushOp(.leftParen)
                re?.cap = numCap
                t += 1

            case UInt8(ascii: "|"):
                try parseVerticalBar()
                t += 1

            case UInt8(ascii: ")"):
                try parseRightParen()
                t += 1

            case UInt8(ascii: "^"):
                try pushOp(parseFlags.contains(.oneLine) ? .beginText : .beginLine)
                t += 1

            case UInt8(ascii: "$"):
                if parseFlags.contains(.oneLine) {
                    let re = try pushOp(.endText)
                    re?.flags.insert(.wasDollar)
                } else {
                    try pushOp(.endLine)
                }
                t += 1

            case UInt8(ascii: "."):
                try pushOp(parseFlags.contains(.dotNL) ? .anyChar : .anyCharNotNL)
                t += 1

            case UInt8(ascii: "["):
                t = try parseClass(t)

            case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"):
                let before = t
                let op: RegexOp =
                    switch inputBytes[t] {
                    case UInt8(ascii: "*"): .star
                    case UInt8(ascii: "+"): .plus
                    default: .quest
                    }
                t = try repeatOp(
                    op, 0, 0, beforeIdx: before, afterIdx: before + 1,
                    lastRepeatIdx: lastRepeat)
                repeatIdx = before

            case UInt8(ascii: "{"):
                let before = t
                if let (min, max, after) = parseRepeat(t) {
                    if min < 0 || min > 1000 || max > 1000 || (max >= 0 && min > max) {
                        // Numbers too big, or max present and min > max.
                        throw RegexError(.invalidRepeatSize, text(before, after))
                    }
                    t = try repeatOp(
                        .repeat, min, max, beforeIdx: before, afterIdx: after,
                        lastRepeatIdx: lastRepeat)
                    repeatIdx = before
                } else {
                    // A `{` that does not start a valid repeat is a literal.
                    try literal(UInt32(UInt8(ascii: "{")))
                    t += 1
                }

            case UInt8(ascii: "\\"):
                var handled = false
                if parseFlags.contains(.perlX), t + 1 < inputBytes.count {
                    switch inputBytes[t + 1] {
                    case UInt8(ascii: "A"):
                        try pushOp(.beginText)
                        t += 2
                        handled = true
                    case UInt8(ascii: "b"):
                        try pushOp(.wordBoundary)
                        t += 2
                        handled = true
                    case UInt8(ascii: "B"):
                        try pushOp(.noWordBoundary)
                        t += 2
                        handled = true
                    case UInt8(ascii: "C"):
                        // Match any byte: not supported.
                        throw RegexError(.invalidEscape, text(t, t + 2))
                    case UInt8(ascii: "Q"):
                        // \Q ... \E quotes everything between as literals.
                        var lit = t + 2
                        let end = Self.findSeq(inputBytes, from: lit, sequence: [
                            UInt8(ascii: "\\"), UInt8(ascii: "E"),
                        ])
                        let litEnd = end ?? inputBytes.count
                        while lit < litEnd {
                            let (c, next) = try Self.nextRune(inputBytes, lit, wholePattern)
                            try literal(c)
                            lit = next
                        }
                        t = end.map { $0 + 2 } ?? inputBytes.count
                        handled = true
                    case UInt8(ascii: "z"):
                        try pushOp(.endText)
                        t += 2
                        handled = true
                    default:
                        break
                    }
                }
                if handled { break }

                let re = makeRegexp(.charClass)
                re.flags = parseFlags

                // \p{Han} and friends.
                if t + 1 < inputBytes.count,
                    inputBytes[t + 1] == UInt8(ascii: "p") || inputBytes[t + 1] == UInt8(ascii: "P")
                {
                    if let (cls, rest) = try parseUnicodeClass(t, []) {
                        re.rune = cls
                        t = rest
                        try pushNode(re)
                        break
                    }
                }

                // \d, \s, \w and their negations.
                if let (cls, rest) = parsePerlClassEscape(t, []) {
                    re.rune = cls
                    t = rest
                    try pushNode(re)
                    break
                }

                // Ordinary single-character escape.
                let (c, next) = try parseEscape(t)
                try literal(c)
                t = next

            default:
                let (c, next) = try Self.nextRune(inputBytes, t, wholePattern)
                try literal(c)
                t = next
            }
            lastRepeat = repeatIdx
        }

        try concat()
        if swapVerticalBar() {
            stack.removeLast()  // pop the vertical bar
        }
        try alternate()

        guard stack.count == 1 else {
            throw RegexError(.missingParen, wholePattern)
        }
        return stack[0]
    }

    /// Go: `literalRegexp`.
    private static func literalRegexp(_ s: String, _ flags: RegexFlags) -> Regexp {
        let re = Regexp(op: .literal)
        re.flags = flags
        re.rune = s.unicodeScalars.map(\.value)
        return re
    }

    /// Find the first occurrence of `sequence` at or after `from`.
    static func findSeq(_ b: [UInt8], from: Int, sequence: [UInt8]) -> Int? {
        guard !sequence.isEmpty, from <= b.count else { return nil }
        var i = from
        while i + sequence.count <= b.count {
            if Array(b[i..<(i + sequence.count)]) == sequence { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Repeat syntax

    /// Go: `parseRepeat` — `{min}`, `{min,}` or `{min,max}`.
    ///
    /// Returns nil when `s` is not of that shape, in which case `{` is a literal.
    /// A `min` of -1 means the numbers were syntactically fine but too large.
    private func parseRepeat(_ start: Int) -> (min: Int, max: Int, after: Int)? {
        var s = start
        guard s < inputBytes.count, inputBytes[s] == UInt8(ascii: "{") else { return nil }
        s += 1
        guard var (min, next) = parseInt(s) else { return nil }
        s = next
        if s >= inputBytes.count { return nil }
        var max = 0
        if inputBytes[s] != UInt8(ascii: ",") {
            max = min
        } else {
            s += 1
            if s >= inputBytes.count { return nil }
            if inputBytes[s] == UInt8(ascii: "}") {
                max = -1
            } else if let (m, n2) = parseInt(s) {
                max = m
                s = n2
                if max < 0 { min = -1 }  // parseInt saw too big a number
            } else {
                return nil
            }
        }
        guard s < inputBytes.count, inputBytes[s] == UInt8(ascii: "}") else { return nil }
        return (min, max, s + 1)
    }

    /// Go: `parseInt`. Leading zeros are rejected; overflow yields -1.
    private func parseInt(_ start: Int) -> (Int, Int)? {
        var s = start
        guard s < inputBytes.count, inputBytes[s] >= UInt8(ascii: "0"), inputBytes[s] <= UInt8(ascii: "9") else {
            return nil
        }
        if s + 1 < inputBytes.count, inputBytes[s] == UInt8(ascii: "0"),
            inputBytes[s + 1] >= UInt8(ascii: "0"), inputBytes[s + 1] <= UInt8(ascii: "9")
        {
            return nil  // disallow leading zeros
        }
        let begin = s
        while s < inputBytes.count, inputBytes[s] >= UInt8(ascii: "0"), inputBytes[s] <= UInt8(ascii: "9") {
            s += 1
        }
        var n = 0
        for i in begin..<s {
            if n >= 100_000_000 {
                n = -1
                break
            }
            n = n * 10 + Int(inputBytes[i] - UInt8(ascii: "0"))
        }
        return (n, s)
    }

    // MARK: - Perl parseFlags and groups

    /// Go: `parsePerlFlags`. The caller guarantees `s` begins with `(?`.
    private mutating func parsePerlFlags(_ start: Int) throws -> Int {
        let s = start
        var t = start

        // Named captures, in the three syntaxes Go accepts:
        //   (?P<name>expr)  (?<name>expr)
        let startsWithP =
            inputBytes.count > s + 4 && inputBytes[s + 2] == UInt8(ascii: "P")
            && inputBytes[s + 3] == UInt8(ascii: "<")
        let startsWithName = inputBytes.count > s + 3 && inputBytes[s + 2] == UInt8(ascii: "<")

        if startsWithP || startsWithName {
            let exprStart = s + (startsWithName ? 3 : 4)
            guard let end = Self.findSeq(inputBytes, from: s, sequence: [UInt8(ascii: ">")]) else {
                try Self.checkUTF8(inputBytes, s, text(from: s))
                throw RegexError(.invalidNamedCapture, text(from: s))
            }
            let capture = text(s, end + 1)  // "(?P<name>" or "(?<name>"
            let name = text(exprStart, end)
            try Self.checkUTF8(inputBytes, exprStart, name)
            guard Self.isValidCaptureName(name) else {
                throw RegexError(.invalidNamedCapture, capture)
            }
            numCap += 1
            let re = try pushOp(.leftParen)
            re?.cap = numCap
            re?.name = name
            return end + 1
        }

        // Non-capturing group, possibly twiddling parseFlags.
        t = s + 2  // skip "(?"
        var f = parseFlags
        var sign = 1
        var sawFlag = false

        loop: while t < inputBytes.count {
            let (c, next) = try Self.nextRune(inputBytes, t, wholePattern)
            t = next
            switch c {
            case UInt32(UInt8(ascii: "i")):
                f.insert(.foldCase)
                sawFlag = true
            case UInt32(UInt8(ascii: "m")):
                f.remove(.oneLine)
                sawFlag = true
            case UInt32(UInt8(ascii: "s")):
                f.insert(.dotNL)
                sawFlag = true
            case UInt32(UInt8(ascii: "U")):
                f.insert(.nonGreedy)
                sawFlag = true

            case UInt32(UInt8(ascii: "-")):
                if sign < 0 { break loop }
                sign = -1
                // Invert so the sets above become clears; inverted back below.
                f = RegexFlags(rawValue: ~f.rawValue)
                sawFlag = false

            case UInt32(UInt8(ascii: ":")), UInt32(UInt8(ascii: ")")):
                if sign < 0 {
                    if !sawFlag { break loop }
                    f = RegexFlags(rawValue: ~f.rawValue)
                }
                if c == UInt32(UInt8(ascii: ":")) {
                    try pushOp(.leftParen)  // open a new group
                }
                parseFlags = f
                return t

            default:
                break loop
            }
        }
        throw RegexError(.invalidPerlOp, text(s, t))
    }

    /// Go: `isValidCaptureName` — `[A-Za-z0-9_]+`.
    private static func isValidCaptureName(_ name: String) -> Bool {
        if name.isEmpty { return false }
        for c in name.unicodeScalars {
            if c.value == UInt32(UInt8(ascii: "_")) { continue }
            if !Self.isAlnum(c.value) { return false }
        }
        return true
    }

    static func isAlnum(_ c: UInt32) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    static func unhexValue(_ c: UInt32) -> Int64 {
        if c >= 0x30 && c <= 0x39 { return Int64(c - 0x30) }
        if c >= 0x61 && c <= 0x66 { return Int64(c - 0x61 + 10) }
        if c >= 0x41 && c <= 0x46 { return Int64(c - 0x41 + 10) }
        return -1
    }

    // MARK: - Vertical bar and parens

    /// Go: `parseVerticalBar`.
    private mutating func parseVerticalBar() throws {
        try concat()
        // If the concatenation sits above an opVerticalBar, swap it below;
        // otherwise push a new bar.
        if !swapVerticalBar() {
            try pushOp(.verticalBar)
        }
    }

    /// Go: `swapVerticalBar`.
    private mutating func swapVerticalBar() -> Bool {
        let n = stack.count
        // If both sides of the bar are classes, merge them into one class.
        if n >= 3, stack[n - 2].op == .verticalBar,
            Self.isCharClassNode(stack[n - 1]), Self.isCharClassNode(stack[n - 3])
        {
            var re1 = stack[n - 1]
            var re3 = stack[n - 3]
            // Make re3 the more complex of the two.
            if re1.op > re3.op {
                swap(&re1, &re3)
                stack[n - 3] = re3
            }
            Self.mergeCharClassNode(re3, re1)
            stack.removeLast()
            return true
        }
        if n >= 2 {
            let re1 = stack[n - 1]
            let re2 = stack[n - 2]
            if re2.op == .verticalBar {
                if n >= 3 {
                    // Now out of reach; clean opportunistically.
                    Self.cleanAltNode(stack[n - 3])
                }
                stack[n - 2] = re1
                stack[n - 1] = re2
                return true
            }
        }
        return false
    }

    /// Go: `parseRightParen`.
    private mutating func parseRightParen() throws {
        try concat()
        if swapVerticalBar() {
            stack.removeLast()  // pop the vertical bar
        }
        try alternate()

        let n = stack.count
        guard n >= 2 else { throw RegexError(.unexpectedParen, wholePattern) }
        let re1 = stack[n - 1]
        let re2 = stack[n - 2]
        stack.removeLast(2)
        guard re2.op == .leftParen else { throw RegexError(.unexpectedParen, wholePattern) }
        // Restore the parseFlags in effect at the open paren.
        parseFlags = re2.flags
        if re2.cap == 0 {
            try pushNode(re1)  // grouping only
        } else {
            re2.op = .capture
            re2.sub = [re1]
            try pushNode(re2)
        }
    }

    /// Go: `isCharClass`.
    static func isCharClassNode(_ re: Regexp) -> Bool {
        (re.op == .literal && re.rune.count == 1)
            || re.op == .charClass || re.op == .anyCharNotNL || re.op == .anyChar
    }

    /// Go: `matchRune`.
    private static func matchRune(_ re: Regexp, _ r: UInt32) -> Bool {
        switch re.op {
        case .literal:
            return re.rune.count == 1 && re.rune[0] == r
        case .charClass:
            var i = 0
            while i + 1 < re.rune.count {
                if re.rune[i] <= r && r <= re.rune[i + 1] { return true }
                i += 2
            }
            return false
        case .anyCharNotNL:
            return r != 0x0A
        case .anyChar:
            return true
        default:
            return false
        }
    }

    /// Go: `mergeCharClass` — `dst = dst|src`, requiring `dst.Op >= src.Op`.
    static func mergeCharClassNode(_ dst: Regexp, _ src: Regexp) {
        switch dst.op {
        case .anyChar:
            break  // src adds nothing
        case .anyCharNotNL:
            if matchRune(src, 0x0A) { dst.op = .anyChar }
        case .charClass:
            if src.op == .literal {
                dst.rune = appendLiteral(dst.rune, src.rune[0], src.flags)
            } else {
                dst.rune = appendClass(dst.rune, src.rune)
            }
        case .literal:
            if src.rune[0] == dst.rune[0] && src.flags == dst.flags { break }
            dst.op = .charClass
            var out = appendLiteral([], dst.rune[0], dst.flags)
            out = appendLiteral(out, src.rune[0], src.flags)
            dst.rune = out
        default:
            break
        }
    }

    // MARK: - UTF-8

    /// Go: `checkUTF8`.
    static func checkUTF8(_ b: [UInt8], _ from: Int, _ expr: String) throws {
        var i = from
        while i < b.count {
            let (r, size) = GoStrconv.decodeRune(b, i)
            if r == 0xFFFD && size == 1 {
                throw RegexError(.invalidUTF8, String(decoding: b[i...], as: UTF8.self))
            }
            i += size
        }
    }

    /// Go: `nextRune`.
    static func nextRune(_ b: [UInt8], _ i: Int, _ wholePattern: String) throws -> (UInt32, Int) {
        let (r, size) = GoStrconv.decodeRune(b, i)
        if r == 0xFFFD && size == 1 {
            throw RegexError(.invalidUTF8, String(decoding: b[i...], as: UTF8.self))
        }
        return (r, i + size)
    }
}
