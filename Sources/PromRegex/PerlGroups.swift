//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/regexp/syntax/perl_groups.go
//
// Transcribed rather than generated: Go's `perlGroup`/`posixGroup` maps are
// unexported, so the oracle cannot read them. Any transcription slip shows up
// immediately in the parse fixtures — `\d` and `[:alnum:]` round-trip through
// String(), so a wrong range changes the output.
//===----------------------------------------------------------------------===//

extension UnicodeTables {

    /// A character group: `sign < 0` means the class is negated.
    typealias CharGroup = (sign: Int, cls: [UInt32])

    // Go: code1 (\d), code2 (\s), code3 (\w).
    private static let codeD: [UInt32] = [0x30, 0x39]
    private static let codeS: [UInt32] = [0x9, 0xA, 0xC, 0xD, 0x20, 0x20]
    private static let codeW: [UInt32] = [0x30, 0x39, 0x41, 0x5A, 0x5F, 0x5F, 0x61, 0x7A]

    /// Go: `perlGroup`.
    static let perlGroups: [String: CharGroup] = [
        #"\d"#: (+1, codeD), #"\D"#: (-1, codeD),
        #"\s"#: (+1, codeS), #"\S"#: (-1, codeS),
        #"\w"#: (+1, codeW), #"\W"#: (-1, codeW),
    ]

    // Go: code4...code17.
    private static let codeAlnum: [UInt32] = [0x30, 0x39, 0x41, 0x5A, 0x61, 0x7A]
    private static let codeAlpha: [UInt32] = [0x41, 0x5A, 0x61, 0x7A]
    private static let codeAscii: [UInt32] = [0x0, 0x7F]
    private static let codeBlank: [UInt32] = [0x9, 0x9, 0x20, 0x20]
    private static let codeCntrl: [UInt32] = [0x0, 0x1F, 0x7F, 0x7F]
    private static let codeDigit: [UInt32] = [0x30, 0x39]
    private static let codeGraph: [UInt32] = [0x21, 0x7E]
    private static let codeLower: [UInt32] = [0x61, 0x7A]
    private static let codePrint: [UInt32] = [0x20, 0x7E]
    private static let codePunct: [UInt32] = [
        0x21, 0x2F, 0x3A, 0x40, 0x5B, 0x60, 0x7B, 0x7E,
    ]
    private static let codeSpace: [UInt32] = [0x9, 0xD, 0x20, 0x20]
    private static let codeUpper: [UInt32] = [0x41, 0x5A]
    private static let codeWord: [UInt32] = [0x30, 0x39, 0x41, 0x5A, 0x5F, 0x5F, 0x61, 0x7A]
    private static let codeXdigit: [UInt32] = [0x30, 0x39, 0x41, 0x46, 0x61, 0x66]

    /// Go: `posixGroup`.
    static let posixGroups: [String: CharGroup] = [
        "[:alnum:]": (+1, codeAlnum), "[:^alnum:]": (-1, codeAlnum),
        "[:alpha:]": (+1, codeAlpha), "[:^alpha:]": (-1, codeAlpha),
        "[:ascii:]": (+1, codeAscii), "[:^ascii:]": (-1, codeAscii),
        "[:blank:]": (+1, codeBlank), "[:^blank:]": (-1, codeBlank),
        "[:cntrl:]": (+1, codeCntrl), "[:^cntrl:]": (-1, codeCntrl),
        "[:digit:]": (+1, codeDigit), "[:^digit:]": (-1, codeDigit),
        "[:graph:]": (+1, codeGraph), "[:^graph:]": (-1, codeGraph),
        "[:lower:]": (+1, codeLower), "[:^lower:]": (-1, codeLower),
        "[:print:]": (+1, codePrint), "[:^print:]": (-1, codePrint),
        "[:punct:]": (+1, codePunct), "[:^punct:]": (-1, codePunct),
        "[:space:]": (+1, codeSpace), "[:^space:]": (-1, codeSpace),
        "[:upper:]": (+1, codeUpper), "[:^upper:]": (-1, codeUpper),
        "[:word:]": (+1, codeWord), "[:^word:]": (-1, codeWord),
        "[:xdigit:]": (+1, codeXdigit), "[:^xdigit:]": (-1, codeXdigit),
    ]

    // MARK: - Special \p{...} tables

    /// Go: `anyTable`.
    static let anyTableRanges: [(lo: UInt32, hi: UInt32, stride: UInt32)] = [
        (0, 0xFFFF, 1), (0x10000, 0x10FFFF, 1),
    ]
    /// Go: `asciiTable`.
    static let asciiTableRanges: [(lo: UInt32, hi: UInt32, stride: UInt32)] = [(0, 0x7F, 1)]
    /// Go: `asciiFoldTable` — ASCII plus the two non-ASCII runes that fold into it.
    static let asciiFoldTableRanges: [(lo: UInt32, hi: UInt32, stride: UInt32)] = [
        (0, 0x7F, 1),
        (0x017F, 0x017F, 1),  // Old English long s (ſ) folds to S/s
        (0x212A, 0x212A, 1),  // Kelvin sign (K) folds to K/k
    ]

    /// Go: `canonicalName` — leading uppercase, rest lowercase, `_`/`-`/space removed.
    static func canonicalName(_ name: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(name.utf8.count)
        var first = true
        for c in name.utf8 {
            if c == UInt8(ascii: "_") || c == UInt8(ascii: "-") || c == UInt8(ascii: " ") {
                continue
            }
            if first {
                out.append(c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z") ? c - 32 : c)
                first = false
            } else {
                out.append(c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z") ? c + 32 : c)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Go: `unicodeTable(name)` — returns the table, its fold companion, and a
    /// sign (negative meaning the result should be inverted).
    static func unicodeTable(
        _ rawName: String
    ) -> (
        tab: [(lo: UInt32, hi: UInt32, stride: UInt32)]?,
        fold: [(lo: UInt32, hi: UInt32, stride: UInt32)]?,
        sign: Int
    ) {
        let name = canonicalName(rawName)

        // Special cases Go handles before the map lookups.
        switch name {
        case "Any": return (anyTableRanges, anyTableRanges, +1)
        case "Assigned": return (categories["Cn"], categories["Cn"], -1)  // invert unassigned
        case "Ascii": return (asciiTableRanges, asciiFoldTableRanges, +1)
        case "Lc":
            // The only non-canonical Categories key.
            return (categories["LC"], foldGroups["LC"], +1)
        default: break
        }
        // Categories, then Scripts. Deliberately NOT Properties: Go's
        // unicodeTable does not consult them, so \p{White_Space} is an error.
        if let t = categories[name] {
            return (t, foldGroups[name], +1)
        }
        if let t = scripts[name] {
            return (t, foldGroups[name], +1)
        }
        if let actual = categoryAliases[name], let t = categories[actual] {
            return (t, foldGroups[actual], +1)
        }
        return (nil, nil, 0)
    }
}
