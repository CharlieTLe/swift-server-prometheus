//===----------------------------------------------------------------------===//
// Ported from tsdb/block.go @ v3.13.2 (`BlockMeta` and friends) and github.com/oklog/ulid/v2.
//
// A block's `meta.json` is the first thing a reader opens and the only part of a block that is JSON, so its
// bytes are a compatibility surface in a way the rest of the TSDB is not: a `meta.json` this port writes has
// to be readable by a real Prometheus, and vice versa.
//
// ## The JSON is emitted BY HAND, and that is not gold-plating
//
// `writeMetaFile` uses `json.MarshalIndent(meta, "", "\t")`. Three properties of that are load-bearing and
// none of them are guaranteed by `JSONEncoder`:
//
//   * **field order is Go STRUCT DECLARATION order** — `ulid`, `minTime`, `maxTime`, `stats`, `compaction`,
//     `version` — not alphabetical. `JSONEncoder` gives no ordering guarantee at all, and `.sortedKeys`
//     gives the wrong one;
//   * **`omitempty` drops zero values**, and it does so per field: `stats` disappears entirely when every
//     counter is zero, but `compaction` has no `omitempty` and is always present even when empty;
//   * **the indent is a TAB**, one per level, with `": "` after each key.
//
// So the encoder is written out longhand. It is more code than `JSONEncoder` and it is the only way to be
// byte-exact.
//
// ## `omitempty` on a STRUCT means "all fields zero", not "nil"
//
// `Stats BlockStats \`json:"stats,omitempty"\`` — Go's `omitempty` does not apply to structs at all, so
// `stats` is in fact **always emitted**. That is a trap in the other direction: reading the tag and
// implementing the omission produces a file Prometheus can still parse but whose bytes differ, which is
// exactly the class of difference this project treats as a bug. The corpus settles it.
//
// ## A ULID is 16 bytes rendered as 26 Crockford base32 characters
//
// Alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ` — no I, L, O or U, which is what makes it
// transcription-safe. 26 characters hold 130 bits for a 128-bit value, so the FIRST character carries only
// 3 significant bits and can never exceed `7`. A ULID string starting with `8` or later is invalid, and
// upstream's decoder rejects it.
//===----------------------------------------------------------------------===//

internal import Foundation
internal import GoCompat

/// Go: `ulid.ULID` — 16 bytes, rendered as 26 Crockford base32 characters.
public struct ULID: Sendable, Hashable, CustomStringConvertible {
    public var bytes: [UInt8]

    /// Go: `ulid.Encoding`. No I, L, O or U.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "a ULID is 16 bytes")
        self.bytes = bytes
    }

    /// Go: `ulid.Parse`. Rejects a wrong length, an out-of-alphabet character, and — see the file header —
    /// a first character above `7`, which would overflow 128 bits.
    public init?(_ s: String) {
        let chars = Array(s.utf8)
        guard chars.count == 26 else { return nil }
        var digits = [UInt8](repeating: 0, count: 26)
        for (i, c) in chars.enumerated() {
            guard let d = ULID.alphabet.firstIndex(of: c) else { return nil }
            digits[i] = UInt8(d)
        }
        // 26 * 5 = 130 bits for a 128-bit value, so the leading character holds only 3.
        if digits[0] > 7 { return nil }

        var out = [UInt8](repeating: 0, count: 16)
        // Pack 130 bits big-endian and drop the top two.
        var acc: UInt64 = 0
        var accBits = 0
        var outIndex = 0
        // Two accumulators would be simpler; instead consume 8 digits (40 bits) at a time into a UInt64.
        var bitBuffer: [UInt8] = []
        for d in digits {
            for shift in stride(from: 4, through: 0, by: -1) {
                bitBuffer.append((d >> UInt8(shift)) & 1)
            }
        }
        // Drop the leading two bits: 130 - 128.
        bitBuffer.removeFirst(2)
        for bit in bitBuffer {
            acc = (acc << 1) | UInt64(bit)
            accBits += 1
            if accBits == 8 {
                out[outIndex] = UInt8(truncatingIfNeeded: acc)
                outIndex += 1
                acc = 0
                accBits = 0
            }
        }
        self.bytes = out
    }

    /// Go: `ulid.ULID.String()`.
    public var description: String {
        // 128 bits into 26 five-bit groups, left-padded to 130.
        var bits: [UInt8] = [0, 0]
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> UInt8(shift)) & 1)
            }
        }
        var out: [UInt8] = []
        var i = 0
        while i < bits.count {
            var v: UInt8 = 0
            for k in 0..<5 {
                v = (v << 1) | bits[i + k]
            }
            out.append(ULID.alphabet[Int(v)])
            i += 5
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Go: `BlockStats`.
public struct BlockStats: Sendable, Equatable {
    public var numSamples: UInt64 = 0
    public var numFloatSamples: UInt64 = 0
    public var numHistogramSamples: UInt64 = 0
    public var numSeries: UInt64 = 0
    public var numChunks: UInt64 = 0
    public var numTombstones: UInt64 = 0

    public init() {}

    var isEmpty: Bool {
        numSamples == 0 && numFloatSamples == 0 && numHistogramSamples == 0 && numSeries == 0
            && numChunks == 0 && numTombstones == 0
    }
}

/// Go: `BlockDesc`.
public struct BlockDesc: Sendable, Equatable {
    public var ulid: ULID
    public var minTime: Int64
    public var maxTime: Int64

    public init(ulid: ULID, minTime: Int64, maxTime: Int64) {
        self.ulid = ulid
        self.minTime = minTime
        self.maxTime = maxTime
    }
}

/// Go: `BlockMetaCompaction`. Note it has **no** `omitempty`, so it is always emitted.
public struct BlockMetaCompaction: Sendable, Equatable {
    public var level: Int = 0
    public var sources: [ULID] = []
    public var deletable: Bool = false
    public var parents: [BlockDesc] = []
    public var failed: Bool = false
    public var hints: [String] = []

    public init() {}
}

/// Go: `BlockMeta`.
public struct BlockMeta: Sendable, Equatable {
    public var ulid: ULID
    public var minTime: Int64
    public var maxTime: Int64
    public var stats = BlockStats()
    public var compaction = BlockMetaCompaction()
    /// Go: `metaVersion1`. `readMetaFile` REJECTS anything else.
    public var version: Int = 1

    public init(ulid: ULID, minTime: Int64, maxTime: Int64) {
        self.ulid = ulid
        self.minTime = minTime
        self.maxTime = maxTime
    }

    /// Go: `json.MarshalIndent(meta, "", "\t")`, spelled out. See the file header for why.
    ///
    /// Two behaviours of `MarshalIndent` that a hand-written encoder gets wrong on the first attempt, and
    /// which 24 of 25 corpus cases caught:
    ///
    ///   * an **empty object collapses to `{}`** on one line — not `{\n\t}`. So `"stats": {}` when every
    ///     counter is zero, with no inner newline at all;
    ///   * **`compaction.level` has NO `omitempty`**, so it is emitted even when zero. Reading the struct
    ///     tags carefully matters more than pattern-matching: `level` is bare, while `sources`,
    ///     `deletable`, `parents`, `failed` and `hints` all carry it.
    public func encodeJSON() -> [UInt8] {
        var out = "{\n"
        out += "\t\"ulid\": \"\(ulid.description)\",\n"
        out += "\t\"minTime\": \(minTime),\n"
        out += "\t\"maxTime\": \(maxTime),\n"

        // Every stats counter carries `omitempty`, so a zero one disappears — and if all of them do, the
        // object collapses to `{}`.
        var statLines: [String] = []
        if stats.numSamples != 0 { statLines.append("\t\t\"numSamples\": \(stats.numSamples)") }
        if stats.numFloatSamples != 0 {
            statLines.append("\t\t\"numFloatSamples\": \(stats.numFloatSamples)")
        }
        if stats.numHistogramSamples != 0 {
            statLines.append("\t\t\"numHistogramSamples\": \(stats.numHistogramSamples)")
        }
        if stats.numSeries != 0 { statLines.append("\t\t\"numSeries\": \(stats.numSeries)") }
        if stats.numChunks != 0 { statLines.append("\t\t\"numChunks\": \(stats.numChunks)") }
        if stats.numTombstones != 0 {
            statLines.append("\t\t\"numTombstones\": \(stats.numTombstones)")
        }
        out += "\t\"stats\": " + object(statLines, indent: "\t") + ",\n"

        var compLines: [String] = []
        // `level` is bare — no `omitempty` — so it is always here.
        compLines.append("\t\t\"level\": \(compaction.level)")
        if !compaction.sources.isEmpty {
            let items = compaction.sources.map { "\t\t\t\"\($0.description)\"" }
            compLines.append("\t\t\"sources\": [\n" + items.joined(separator: ",\n") + "\n\t\t]")
        }
        if compaction.deletable { compLines.append("\t\t\"deletable\": true") }
        if !compaction.parents.isEmpty {
            let items = compaction.parents.map { p in
                "\t\t\t{\n\t\t\t\t\"ulid\": \"\(p.ulid.description)\",\n"
                    + "\t\t\t\t\"minTime\": \(p.minTime),\n"
                    + "\t\t\t\t\"maxTime\": \(p.maxTime)\n\t\t\t}"
            }
            compLines.append("\t\t\"parents\": [\n" + items.joined(separator: ",\n") + "\n\t\t]")
        }
        if compaction.failed { compLines.append("\t\t\"failed\": true") }
        if !compaction.hints.isEmpty {
            let items = compaction.hints.map { "\t\t\t\(jsonQuote($0))" }
            compLines.append("\t\t\"hints\": [\n" + items.joined(separator: ",\n") + "\n\t\t]")
        }
        out += "\t\"compaction\": " + object(compLines, indent: "\t") + ",\n"

        out += "\t\"version\": \(version)\n"
        out += "}"
        return Array(out.utf8)
    }

    /// `MarshalIndent`'s object rendering: `{}` when empty, otherwise one field per line.
    private func object(_ lines: [String], indent: String) -> String {
        if lines.isEmpty { return "{}" }
        return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
    }
}

/// Go: `encoding/json`'s string escaping, which is NOT `strconv.Quote`'s.
///
/// The differences that matter for a `hints` string: `<`, `>` and `&` are escaped as `<`, `>` and
/// `&` by default (Go's HTML-escaping, on unless `SetEscapeHTML(false)`), and ` `/` ` are
/// escaped too. `strconv.Quote` does none of that, so reusing `GoStrconv.quote` here would be wrong.
func jsonQuote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "<": out += "\\u003c"
        case ">": out += "\\u003e"
        case "&": out += "\\u0026"
        case "\u{2028}": out += "\\u2028"
        case "\u{2029}": out += "\\u2029"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}
