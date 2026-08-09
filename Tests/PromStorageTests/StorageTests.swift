//===----------------------------------------------------------------------===//
// Differential tests for storage/interface.go's errors, storage/errors.go and
// tsdb/chunkenc/chunk.go's enums.
//
// These are Phase 5's protocol substrate: no logic yet, but every string and
// every enum mapping here is something a later phase will assert against, so
// pinning them now means a reworded message fails at the point it changes rather
// than inside the engine.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromChunkEnc
import PromLabels
import Testing

@testable import PromStorage

@Suite("storage error strings match Go")
struct StorageErrorTests {

    /// The oracle's sentinel names, mapped to this port's cases. Written out
    /// rather than derived, so a case added upstream fails to compile here instead
    /// of silently going unchecked.
    static let sentinels: [String: StorageError] = [
        "NotFound": .notFound,
        "OutOfOrderSample": .outOfOrderSample,
        "OutOfBounds": .outOfBounds,
        "TooOldSample": .tooOldSample,
        "OutOfOrderExemplar": .outOfOrderExemplar,
        "DuplicateExemplar": .duplicateExemplar,
        "ExemplarLabelLength": .exemplarLabelLength,
        "ExemplarsDisabled": .exemplarsDisabled,
        "NativeHistogramsDisabled": .nativeHistogramsDisabled,
        "OutOfOrderST": .outOfOrderST,
        "STNewerThanSample": .stNewerThanSample,
    ]

    @Test("every package-level error renders Go's message")
    func sentinelMessages() throws {
        try Fixtures.check("storage/errors.jsonl", FixtureCase<String, String>.self) { name in
            if name == "DuplicateSampleForTimestamp" {
                // Not a StorageError case: it carries data, so it is its own type
                // whose zero value is the sentinel.
                return DuplicateSampleForTimestampError.sentinel.description
            }
            guard let e = Self.sentinels[name] else {
                return "no case for \(name)"
            }
            return e.description
        }
    }

    struct DupIn: Decodable, Sendable {
        let kind: String
        let timestamp: Int64
        let existing: String
        let newValue: String

        var existingValue: Double { DupIn.decode(existing) }
        var newValueValue: Double { DupIn.decode(newValue) }

        private static func decode(_ hex: String) -> Double {
            guard let bits = UInt64(hex, radix: 16) else { return 0 }
            return Double(bitPattern: bits)
        }
    }

    struct DupOut: Decodable, Equatable, Sendable {
        let message: String
        let isSentinel: Bool
    }

    @Test("the duplicate-sample messages match Go")
    func duplicateMessages() throws {
        try Fixtures.check("storage/duplicate.jsonl", FixtureCase<DupIn, DupOut>.self) { input in
            let err: DuplicateSampleForTimestampError
            switch input.kind {
            case "float":
                err = .duplicateFloat(
                    t: input.timestamp, existing: input.existingValue,
                    newValue: input.newValueValue)
            default:
                err = .duplicateHistogramToFloat(
                    t: input.timestamp, newValue: input.newValueValue)
            }
            return DupOut(
                message: err.description,
                isSentinel: isDuplicateSampleForTimestamp(err))
        }
    }
}

@Suite("chunkenc enums match Go")
struct ChunkEncEnumTests {

    struct EncOut: Decodable, Equatable, Sendable {
        let string: String
        let isValid: Bool
    }

    struct ValueTypeOut: Decodable, Equatable, Sendable {
        let string: String
        let encodingXOR2: String
        let encodingNotXOR2: String
    }

    struct CompatibleIn: Decodable, Sendable {
        let a: UInt8
        let b: UInt8
    }

    @Test("Encoding.String and IsValidEncoding match Go")
    func encoding() throws {
        try Fixtures.check("chunkenc/encoding.jsonl", FixtureCase<UInt8, EncOut>.self) { raw in
            let enc = Encoding(rawValue: raw)
            return EncOut(string: enc.description, isValid: enc.isValid)
        }
    }

    @Test("ValueType.String and ChunkEncoding match Go")
    func valueType() throws {
        try Fixtures.check("chunkenc/valuetype.jsonl", FixtureCase<UInt8, ValueTypeOut>.self) {
            raw in
            let vt = ValueType(rawValue: raw)
            return ValueTypeOut(
                string: vt.description,
                encodingXOR2: vt.chunkEncoding(useXOR2: true).description,
                encodingNotXOR2: vt.chunkEncoding(useXOR2: false).description)
        }
    }

    @Test("CompatibleValues matches Go over the encoding cross product")
    func compatible() throws {
        try Fixtures.check("chunkenc/compatible.jsonl", FixtureCase<CompatibleIn, Bool>.self) {
            input in
            compatibleValues(Encoding(rawValue: input.a), Encoding(rawValue: input.b))
        }
    }
}

// MARK: - Properties the fixtures cannot state

@Suite("storage protocol invariants")
struct StorageProtocolTests {

    @Test("the empty and error series sets terminate immediately")
    func emptySets() {
        let empty = emptySeriesSet()
        #expect(!empty.next())
        #expect(empty.at() == nil)
        #expect(empty.err() == nil)
        #expect(empty.warnings().isEmpty)

        let failed = errSeriesSet(StorageError.notFound)
        #expect(!failed.next())
        #expect(failed.err() != nil)
    }

    @Test("noop queriers hand back empty sets rather than nil")
    func noopQueriers() throws {
        let q = noopQuerier()
        let set = q.select(
            GoContext.background(), sortSeries: false, hints: nil, matchers: [])
        #expect(!set.next())
        let (values, warnings) = try q.labelValues(
            GoContext.background(), name: "x", hints: nil, matchers: [])
        #expect(values.isEmpty)
        #expect(warnings.isEmpty)
        try q.close()
    }

    @Test("testSeriesSet never terminates, as upstream's tests rely on")
    func testSeriesSetNeverEnds() {
        // interface.go:555 — Next() is unconditionally true. Surprising enough to
        // pin, since a "fix" here would break the upstream tests that use it.
        final class Stub: Series {
            func labels() -> Labels { Labels.empty }
            func iterator(_: (any ChunkIterator)?) -> any ChunkIterator { newNopIterator() }
        }
        let set = TestSeriesSet(Stub())
        #expect(set.next())
        #expect(set.next())
        #expect(set.at() != nil)
    }

    @Test("the nop iterator reports MinInt64 for time but 0 for start time")
    func nopIterator() {
        // chunk.go:308-317 — At/AtT give math.MinInt64 while AtST gives 0. The
        // asymmetry is real and a caller could depend on it.
        let it = newNopIterator()
        #expect(it.next() == ValueType.none)
        #expect(it.seek(0) == ValueType.none)
        #expect(it.atT() == Int64.min)
        #expect(it.atST() == 0)
        #expect(it.at() == (Int64.min, 0))
        #expect(it.atHistogram(nil).1 == nil)
        #expect(it.err() == nil)
    }

    @Test("the mock series iterator's seek does nothing")
    func mockIteratorSeek() {
        // chunk.go:263 — Seek always returns ValNone even with samples remaining.
        let it = MockSeriesChunkIterator(
            startTimestamps: [], timestamps: [1, 2, 3], values: [10, 20, 30])
        #expect(it.seek(1) == ValueType.none)
        #expect(it.next() == ValueType.float)
        #expect(it.at() == (1, 10))
        #expect(it.atST() == 0)
        #expect(it.next() == ValueType.float)
        #expect(it.next() == ValueType.float)
        #expect(it.next() == ValueType.none)
    }
}
