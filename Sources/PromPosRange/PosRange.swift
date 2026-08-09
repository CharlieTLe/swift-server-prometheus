//===----------------------------------------------------------------------===//
// Ported from promql/parser/posrange/posrange.go @ v3.13.2
//===----------------------------------------------------------------------===//

/// Go: `posrange.Pos` — a position in a string, in **bytes**. Negative values
/// mean the position is undefined.
public typealias Pos = Int32

/// Go: `posrange.PositionRange` — a range in the parser's input string.
public struct PositionRange: Sendable, Hashable {
    /// Start of the range, zero-indexed.
    public var start: Pos
    /// End of the range, zero-indexed.
    public var end: Pos

    public init(start: Pos, end: Pos) {
        self.start = start
        self.end = end
    }

    /// Go: `StartPosInput` — renders the start as `line:col` against the query
    /// text, or says why it cannot.
    ///
    /// `lineOffset` is an extra line offset that upstream only uses from its own
    /// unit tests, kept because `ParseErr`'s rendering takes it.
    public func startPosInput(query: [UInt8], lineOffset: Int = 0) -> String {
        if query.isEmpty {
            return "unknown position"
        }
        let pos = Int(start)
        if pos < 0 || pos > query.count {
            return "invalid position"
        }

        // Go ranges over the string, so the index is a BYTE offset even though the
        // loop yields runes. Counting bytes here matches that: only '\n' is being
        // looked for, and it cannot occur inside a multi-byte sequence.
        var lastLineBreak = -1
        var line = lineOffset + 1
        for i in 0..<pos where query[i] == UInt8(ascii: "\n") {
            lastLineBreak = i
            line += 1
        }
        let col = pos - lastLineBreak
        return "\(line):\(col)"
    }

    public func startPosInput(query: String, lineOffset: Int = 0) -> String {
        startPosInput(query: Array(query.utf8), lineOffset: lineOffset)
    }
}
