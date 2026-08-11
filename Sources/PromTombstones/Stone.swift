//===----------------------------------------------------------------------===//
// Ported from tsdb/tombstones/tombstones.go @ v3.13.2 — `Stone` only.
//
// A `Stone` is one series' worth of deletion intervals, and it is the unit the WAL's Tombstones record
// carries. The file reader (`ReadTombstones`, `WriteFile`, `MemTombstones`) is still deliberately not
// ported — PORTING.md exception 16 — because its only caller is the block's on-disk `tombstones` file,
// which needs the Head to produce. This type is here because `record.Encoder.Tombstones` and
// `record.Decoder.Tombstones` take it, and those are Phase 7's first slice.
//
// ## One `Stone` becomes N wire entries, and decoding gives back N `Stone`s
//
// `Encoder.Tombstones` writes `[BE64 ref][varint mint][varint maxt]` **per interval**, so a stone with
// three intervals occupies three entries. `Decoder.Tombstones` builds one `Stone` per entry, each with a
// single-element `Intervals`. So the round trip is NOT the identity on the Swift side either: three
// intervals in, three stones out. That asymmetry is upstream's and `head_wal.go` relies on it — it feeds
// each decoded stone through `MemTombstones.AddInterval`, which merges.
//===----------------------------------------------------------------------===//

public import PromStorage

/// Go: `tombstones.Stone`.
public struct Stone: Sendable, Equatable {
    public var ref: SeriesRef
    /// Go: `tombstones.Intervals`, which is `[]Interval`.
    public var intervals: [DeletionInterval]

    public init(ref: SeriesRef, intervals: [DeletionInterval]) {
        self.ref = ref
        self.intervals = intervals
    }
}
