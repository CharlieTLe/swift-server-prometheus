//===----------------------------------------------------------------------===//
// Differential tests for the histogram generic layer.
//
// The bound *table* is generated from Go, so it cannot disagree. What these pin is
// the surrounding logic: the MaxFloat64 clamp on the last regular bucket, the
// Ldexp path for negative schemas, and the ±Inf edges of custom-bucket lookup.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import Testing

@testable import PromHistogram

struct BoundIn: Decodable, Sendable {
    let idx: Int32
    let schema: Int32
    let customValues: [String]
    var custom: [Double] { customValues.map { Double(bitPattern: UInt64($0, radix: 16)!) } }
}

struct BoundOut: Decodable, Equatable, Sendable {
    let lower: String
    let upper: String
    let lowerInclusive: Bool
    let upperInclusive: Bool
}

@Suite("Histogram bounds match Go")
struct BoundsTests {

    @Test("every committed fixture case")
    func fixtures() throws {
        try Fixtures.check("histogram/bounds.jsonl", FixtureCase<BoundIn, BoundOut>.self) { input in
            // Mirrors what baseBucketIterator.at() computes for a positive bucket.
            let upper = getBound(input.idx, input.schema, input.custom)
            let lower = getBound(input.idx - 1, input.schema, input.custom)
            let lowerInclusive: Bool
            let upperInclusive: Bool
            if isCustomBucketsSchema(input.schema) {
                lowerInclusive = input.idx == 0
                upperInclusive = true
            } else {
                lowerInclusive = lower < 0
                upperInclusive = upper > 0
            }
            return BoundOut(
                lower: String(format: "%016lx", lower.bitPattern),
                upper: String(format: "%016lx", upper.bitPattern),
                lowerInclusive: lowerInclusive,
                upperInclusive: upperInclusive)
        }
    }

    @Test("the last regular bucket is clamped to greatestFiniteMagnitude")
    func maxFloatClamp() {
        // Applying the usual formula would give +Inf, but ±Inf observations belong
        // in the NEXT bucket, so Go clamps this one boundary.
        for schema in Int32(1)...8 {
            let last = Int32(1024) << schema
            #expect(
                getBoundExponential(last, schema) == .greatestFiniteMagnitude,
                "schema \(schema)")
            // The bucket above it is the ±Inf overflow bucket.
            #expect(getBoundExponential(last + 1, schema).isInfinite, "schema \(schema)")
        }
        // Negative schemas take the Ldexp path with the same clamp at exp == 1024.
        for schema in Int32(-4)...(-1) {
            let last = Int32(1024) >> (-schema)
            #expect(
                getBoundExponential(last, schema) == .greatestFiniteMagnitude,
                "schema \(schema)")
        }
    }

    @Test("schema 0 bounds are powers of two")
    func schemaZero() {
        #expect(getBoundExponential(0, 0) == 1)
        #expect(getBoundExponential(1, 0) == 2)
        #expect(getBoundExponential(2, 0) == 4)
        #expect(getBoundExponential(-1, 0) == 0.5)
        #expect(getBoundExponential(-2, 0) == 0.25)
    }

    @Test("custom-bucket lookup handles the ±Inf edges")
    func customBounds() {
        let custom = [0.5, 1.0, 2.5, 10.0]
        #expect(getBound(0, HistogramSchema.customBuckets, custom) == 0.5)
        #expect(getBound(3, HistogramSchema.customBuckets, custom) == 10.0)
        // idx == count is the implicit final +Inf bucket.
        #expect(getBound(4, HistogramSchema.customBuckets, custom) == .infinity)
        // idx == -1 is the lower edge of the first bucket.
        #expect(getBound(-1, HistogramSchema.customBuckets, custom) == -.infinity)
    }

    @Test("the generated bound table is exact")
    func boundTable() {
        // Recovered from Go rather than transcribed; 511 values across schemas 0-8.
        #expect(HistogramTables.exponentialBoundBits.count == 9)
        for schema in 0...8 {
            #expect(HistogramTables.exponentialBoundBits[schema].count == 1 << schema)
        }
        #expect(HistogramTables.exponentialBound(schema: 0, index: 0) == 0.5)
        // Schema 1 index 1 is sqrt(0.5) — the halfway point in log space.
        #expect(
            HistogramTables.exponentialBound(schema: 1, index: 1) == 0.7071067811865475)
    }
}

@Suite("Histogram schema predicates")
struct SchemaTests {

    @Test("valid, reserved and known schema ranges")
    func ranges() {
        // Supported exponential range is -4...8.
        #expect(isExponentialSchema(-4))
        #expect(isExponentialSchema(8))
        #expect(!isExponentialSchema(-5))
        #expect(!isExponentialSchema(9))
        // The reserved range is wider: Prometheus accepts these but reduces resolution.
        #expect(isExponentialSchemaReserved(-9))
        #expect(isExponentialSchemaReserved(52))
        #expect(!isExponentialSchemaReserved(53))

        #expect(isCustomBucketsSchema(-53))
        #expect(!isCustomBucketsSchema(-52))

        // Valid == supported exponential or custom buckets.
        #expect(isValidSchema(-53))
        #expect(isValidSchema(0))
        #expect(!isValidSchema(20))
        // Known == accepted after resolution reduction.
        #expect(isKnownSchema(20))
        #expect(isKnownSchema(-53))
        #expect(!isKnownSchema(-10))
    }

    @Test("targetIdx maps an index between schemas")
    func targetIndex() {
        // Halving the resolution merges bucket pairs.
        #expect(targetIdx(1, 1, 0) == 1)
        #expect(targetIdx(2, 1, 0) == 1)
        #expect(targetIdx(3, 1, 0) == 2)
        #expect(targetIdx(4, 1, 0) == 2)
    }

    @Test("custom bound comparison is exact, including length")
    func boundsMatch() {
        #expect(customBucketBoundsMatch([1, 2, 3], [1, 2, 3]))
        #expect(!customBucketBoundsMatch([1, 2, 3], [1, 2]))
        #expect(!customBucketBoundsMatch([1, 2, 3], [1, 2, 4]))
        #expect(customBucketBoundsMatch([], []))
        // NaN never equals itself, so a NaN bound makes the sets unequal.
        #expect(!customBucketBoundsMatch([.nan], [.nan]))
    }
}
