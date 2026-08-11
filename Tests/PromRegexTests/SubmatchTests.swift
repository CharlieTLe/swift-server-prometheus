//===----------------------------------------------------------------------===//
// `FindStringSubmatchIndex` and `ExpandString`, which is all `label_replace` is.
//
// Every pattern is compiled the way `evalLabelReplace` compiles it — `"^(?s:" + re + ")$"` — because a
// pattern that behaves differently unanchored is not what the caller sees.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromRegex
import Testing

struct SubmatchIn: Codable, Sendable {
    var pattern: String
    /// Hex, not a string. Go's `encoding/json` repairs invalid UTF-8 on the way out, so a string field
    /// would hand the port a different subject than the one Go was measured on — which two cases
    /// caught, both of them a lone `0x80`.
    var subject: String
    var template: String
}

struct SubmatchOut: Decodable, Equatable, Sendable {
    var matched: Bool?
    var index: [Int]?
    var expandedHex: String?
    var numSubexp: Int?
    var names: [String]?
    var err: String?
}

private func unhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func hex(_ b: [UInt8]) -> String {
    b.map { String(format: "%02x", $0) }.joined()
}

@Suite("regexp: submatch indices and template expansion")
struct SubmatchTests {

    @Test("every committed case matches Go")
    func matchesGo() throws {
        try Fixtures.check("regex/submatch.jsonl", FixtureCase<SubmatchIn, SubmatchOut>.self) {
            input in
            var out = SubmatchOut(
                matched: nil, index: nil, expandedHex: nil, numSubexp: nil, names: nil, err: nil)
            let re: CompiledRegex
            do {
                re = try CompiledRegex(anchoredForLabelReplace: input.pattern)
            } catch {
                // The error TEXT is compared, because `PromRegex` reproduces Go's `syntax.Error`
                // messages and a divergence there would show up in
                // `invalid regular expression in label_replace()`'s neighbours even though that
                // message discards it.
                out.err = String(describing: error)
                return out
            }
            out.numSubexp = re.numSubexp
            out.names = re.subexpNames
            let subject = unhex(input.subject)
            if let idx = re.findSubmatchIndex(subject) {
                out.matched = true
                out.index = idx
                out.expandedHex = hex(re.expand([], unhex(input.template), subject, idx))
            } else {
                out.matched = false
            }
            return out
        }
    }
}
