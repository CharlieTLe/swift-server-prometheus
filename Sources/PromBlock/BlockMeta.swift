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

public import PromFS

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

    /// Go: `ulid.New(ms uint64, entropy io.Reader)` — the six-byte big-endian millisecond timestamp followed
    /// by ten bytes of entropy.
    ///
    /// `ulid.MustNew(ulid.Now(), rand.Reader)` is how `compact.go` names every block it writes, so the six
    /// leading bytes are the WALL CLOCK at write time and the rest is `crypto/rand`. A block's identity is
    /// therefore not a function of its contents: write the same samples twice and the two blocks differ in
    /// their directory name and in two fields of `meta.json` and nowhere else. Quirk 196.
    ///
    /// `ulid.New` errors with `ulid: timestamp too big` above 2**48-1; `MustNew` panics on it, and no caller
    /// in `tsdb` can reach it because `ulid.Now()` is `uint64(time.Now().UnixMilli())`.
    public init(timestampMS: UInt64, entropy: [UInt8]) {
        precondition(entropy.count == 10, "a ULID's entropy is 10 bytes")
        // 2**48 - 1, spelled as the value it denotes: HANDOFF §4 on untyped integer expressions and the
        // Swift 6.1 floor.
        precondition(timestampMS <= 281_474_976_710_655, "ulid: timestamp too big")
        var out = [UInt8](repeating: 0, count: 16)
        out[0] = UInt8(truncatingIfNeeded: timestampMS >> 40)
        out[1] = UInt8(truncatingIfNeeded: timestampMS >> 32)
        out[2] = UInt8(truncatingIfNeeded: timestampMS >> 24)
        out[3] = UInt8(truncatingIfNeeded: timestampMS >> 16)
        out[4] = UInt8(truncatingIfNeeded: timestampMS >> 8)
        out[5] = UInt8(truncatingIfNeeded: timestampMS)
        for i in 0..<10 { out[6 + i] = entropy[i] }
        self.bytes = out
    }

    /// Go: `ulid.MustNew(ulid.Now(), rand.Reader)`.
    public static func newRandom() -> ULID {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        var rng = SystemRandomNumberGenerator()
        var entropy = [UInt8](repeating: 0, count: 10)
        for i in 0..<10 { entropy[i] = UInt8.random(in: 0...255, using: &rng) }
        return ULID(timestampMS: ms, entropy: entropy)
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

    /// Go: `CompactionHintFromOutOfOrder`.
    public static let hintFromOutOfOrder = "from-out-of-order"
    /// Go: `CompactionHintFromStaleSeries`.
    public static let hintFromStaleSeries = "from-stale-series"

    /// Go: `SetOutOfOrder` — idempotent, and it **re-sorts the whole hint list** afterwards rather than
    /// appending in call order. So the two hints always come out alphabetically, whichever was set first.
    public mutating func setOutOfOrder() {
        if fromOutOfOrder() { return }
        hints.append(Self.hintFromOutOfOrder)
        hints.sort()
    }

    /// Go: `FromOutOfOrder`.
    public func fromOutOfOrder() -> Bool { hints.contains(Self.hintFromOutOfOrder) }

    /// Go: `SetStaleSeries`.
    public mutating func setStaleSeries() {
        if fromStaleSeries() { return }
        hints.append(Self.hintFromStaleSeries)
        hints.sort()
    }

    /// Go: `FromStaleSeries`.
    public func fromStaleSeries() -> Bool { hints.contains(Self.hintFromStaleSeries) }
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

// MARK: - Reading meta.json

extension BlockMeta {
    /// Go: `readMetaFile` — `json.Unmarshal` then a version check.
    ///
    /// A hand-written parser rather than `JSONDecoder`, for a reason that is the mirror of the encoder's:
    /// Go's `Unmarshal` is **lenient** in ways `JSONDecoder` is not. It ignores unknown fields (so a block
    /// from a newer Prometheus with an extra key still opens), and it leaves absent fields at their zero
    /// value rather than failing. `JSONDecoder` matches on the second point but a `Codable` struct with a
    /// non-optional field errors on an absent key, which would reject the very files `omitempty` produces —
    /// and `omitempty` means *most* real files omit *most* fields.
    ///
    /// So: parse permissively, default everything, and check only what upstream checks — the version.
    public init(json bytes: [UInt8]) throws {
        guard let root = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        else {
            throw BlockError.malformedMeta("not a JSON object")
        }

        func i64(_ any: Any?) -> Int64 {
            if let n = any as? NSNumber { return n.int64Value }
            return 0
        }
        func u64(_ any: Any?) -> UInt64 {
            if let n = any as? NSNumber { return n.uint64Value }
            return 0
        }

        guard let ulidString = root["ulid"] as? String, let parsed = ULID(ulidString) else {
            throw BlockError.malformedMeta("missing or invalid ulid")
        }
        self.init(
            ulid: parsed, minTime: i64(root["minTime"]), maxTime: i64(root["maxTime"]))

        // Go checks the version and NOTHING else, so an unknown field is ignored rather than rejected.
        let version = Int(i64(root["version"]))
        if version != 1 {
            throw BlockError.unexpectedMetaVersion(version)
        }
        self.version = version

        if let st = root["stats"] as? [String: Any] {
            stats.numSamples = u64(st["numSamples"])
            stats.numFloatSamples = u64(st["numFloatSamples"])
            stats.numHistogramSamples = u64(st["numHistogramSamples"])
            stats.numSeries = u64(st["numSeries"])
            stats.numChunks = u64(st["numChunks"])
            stats.numTombstones = u64(st["numTombstones"])
        }
        if let c = root["compaction"] as? [String: Any] {
            compaction.level = Int(i64(c["level"]))
            compaction.deletable = (c["deletable"] as? Bool) ?? false
            compaction.failed = (c["failed"] as? Bool) ?? false
            compaction.hints = (c["hints"] as? [String]) ?? []
            compaction.sources = ((c["sources"] as? [String]) ?? []).compactMap(ULID.init)
            for p in (c["parents"] as? [[String: Any]]) ?? [] {
                guard let us = p["ulid"] as? String, let u = ULID(us) else { continue }
                compaction.parents.append(
                    BlockDesc(ulid: u, minTime: i64(p["minTime"]), maxTime: i64(p["maxTime"])))
            }
        }
    }
}

// MARK: - Writing meta.json, and the block directory's layout

/// Go: `indexFilename`.
public let indexFilename = "index"
/// Go: `metaFilename`.
public let metaFilename = "meta.json"
/// Go: `tombstones.TombstonesFilename`. Named here because the LAYOUT is `block.go`'s; the file CODEC is
/// `tsdb/tombstones`' and is not ported (exception 16 for reading, exception 26 for writing).
public let tombstonesFilename = "tombstones"

/// Go: `chunkDir(dir)`.
public func blockChunkDir(_ dir: String) -> String { dir + "/chunks" }

extension BlockMeta {

    /// Go: `writeMetaFile(logger, dir, meta)` — returns the number of bytes written.
    ///
    /// Two things about it that the name does not give:
    ///
    ///   * **it MUTATES the caller's meta.** `meta.Version = metaVersion1` is the first statement
    ///     (block.go:276), so a `BlockMeta{}` built with no version still lands as version 1. The port takes
    ///     `inout` rather than defaulting the field, because the mutation is observable: `compact.go`'s
    ///     caller keeps reading the same struct afterwards.
    ///   * **the write is `<path>.tmp` then `fileutil.Replace`**, so a reader never sees a half-written
    ///     `meta.json`, and the `.tmp` is removed on *every* exit path — success included, which is why the
    ///     removal is in Go's `defer`. ADR-15 gives `PromFS` no rename, so the port copies and removes; the
    ///     end state is identical and the crash window is not (exception 28, the same arrangement as
    ///     exception 25's).
    ///
    /// The returned count is `len(jsonMeta)` — the length of the JSON, which is what `Block.numBytesMeta`
    /// records. It is not `Stat`ed off the file.
    @discardableResult
    public static func writeMetaFile(fs: any PromFS, dir: String, meta: inout BlockMeta) throws -> Int64 {
        meta.version = 1

        let path = dir + "/" + metaFilename
        let tmp = path + ".tmp"

        let jsonMeta = meta.encodeJSON()
        let f = try fs.createFile(tmp)
        try f.append(jsonMeta)
        try f.flush()
        try f.sync()
        try f.close()

        let r = try fs.openForReading(tmp)
        let bytes = try r.read(offset: 0, length: r.size)
        try r.close()
        let final = try fs.createFile(path)
        try final.append(bytes)
        try final.flush()
        try final.sync()
        try final.close()
        try? fs.remove(tmp)

        return Int64(jsonMeta.count)
    }
}
