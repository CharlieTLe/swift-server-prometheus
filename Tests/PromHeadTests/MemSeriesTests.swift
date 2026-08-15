//===----------------------------------------------------------------------===//
// `memSeries`' in-order chunk state, pinned against Go — the cut rules, the linked list, `appendable`'s
// verdicts, m-mapping and truncation.
//
// The corpus drives `oracle/probe/headmemseries`, a lift of the unexported upstream code into its own
// package: nothing on `Head`'s exported surface reaches `memSeries` until `head_read.go`, so there is no
// entry point for the oracle to use instead. `oracle/suites_head_memseries.go` has the case list and that
// package's header has the five deltas the lift makes.
//
// The committed output carries chunk BYTES, so a port that got every count and boundary right and still
// encoded the samples differently would fail here.
//===----------------------------------------------------------------------===//

import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromFS
import PromHistogram
import PromLabels
import Testing

@testable import PromHead

// MARK: - Wire types

struct MSOp: Codable, Sendable {
    var op: String
    var st: Int64?
    var t: Int64?
    var v: String?
    var appendID: UInt64?
    var headMaxt: Int64?
    var minValidTime: Int64?
    var oooTimeWindow: Int64?
    var mint: Int64?
    var maxt: Int64?
    var bound: UInt64?
    var offset: Int?
    var useXOR2: Bool?
    var storeST: Bool?
    var mmapped: [MSMmappedState]?
}

struct MSIn: Codable, Sendable {
    var chunkRange: Int64
    var samplesPerChunk: Int
    var useXOR2: Bool?
    var storeST: Bool?
    var ref: UInt64
    var shardHash: UInt64?
    var isolationDisabled: Bool?
    var pendingCommit: Bool?
    var ops: [MSOp]
}

struct MSChunkState: Codable, Equatable, Sendable {
    var minTime: Int64
    var maxTime: Int64
    var encoding: UInt8
    var numSamples: Int
    var bytes: String
}

struct MSMmappedState: Codable, Equatable, Sendable {
    var ref: UInt64
    var numSamples: UInt16
    var minTime: Int64
    var maxTime: Int64
}

struct MSState: Codable, Equatable, Sendable {
    var minTime: Int64
    var maxTime: Int64
    var nextAt: Int64
    var headCount: UInt32
    var firstChunkID: UInt64
    var lastValue: String
    var hasLastHistogram: Bool?
    var hasLastFloatHistogram: Bool?
    var hasApp: Bool
    var headChunks: [MSChunkState]
    var mmappedChunks: [MSMmappedState]
    var txIDs: [UInt64]
    var hasTxRing: Bool
}

struct MSOpOut: Codable, Equatable, Sendable {
    var sampleInOrder: Bool?
    var chunkCreated: Bool?
    var isOOO: Bool?
    var oooDelta: Int64?
    var err: String?
    var count: Int?
    var found: Bool?
    var minTime: Int64?
    var overlaps: Bool?
}

struct MSFileState: Codable, Equatable, Sendable {
    var name: String
    var size: Int
    var bytes: String
}

struct MSOut: Codable, Equatable, Sendable {
    var ops: [MSOpOut]
    var states: [MSState]
    /// The chunk files after the mapper closes. Without them `mmapChunks`' `mint`/`maxt` arguments are
    /// unobservable — the `MmappedChunk` record keeps its own copies.
    var files: [MSFileState]
}

// The corpus ships floats as their 64-bit pattern, because `appendable` compares bits: -0 and 0 differ to it
// and two identical NaNs do not.
private func fbits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
private func hbits(_ d: Double) -> String { String(format: "%016lx", d.bitPattern) }
private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
// The shared codec, so this suite and the head-chunk one cannot drift apart.
private func rleHex(_ b: [UInt8]) -> String { RLEHex.encode(b) }

// Go's `omitempty` drops false/0/"" on the way out, so the port must too — otherwise every case would
// "mismatch" on fields Go never wrote.
private func z(_ b: Bool) -> Bool? { b ? true : nil }
private func z(_ i: Int) -> Int? { i == 0 ? nil : i }
private func z(_ i: Int64) -> Int64? { i == 0 ? nil : i }
private func z(_ s: String) -> String? { s.isEmpty ? nil : s }

@Suite("head: memSeries' chunk state, the cut rules and m-mapping")
struct MemSeriesTests {

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("head/memseries.jsonl", FixtureCase<MSIn, MSOut>.self) { input in
            let fs = InMemoryFS()
            try fs.createDirectory("chunks_head")
            let cdm = try ChunkDiskMapper(fs: fs, dir: "chunks_head")

            let s = MemSeries(
                labels: Labels(),
                ref: HeadSeriesRef(rawValue: input.ref),
                shardHash: input.shardHash ?? 0,
                isolationDisabled: input.isolationDisabled ?? false,
                pendingCommit: input.pendingCommit ?? false)

            var o = ChunkOpts(
                chunkDiskMapper: cdm, chunkRange: input.chunkRange,
                samplesPerChunk: input.samplesPerChunk,
                useXOR2: input.useXOR2 ?? false, storeST: input.storeST ?? false)

            func snapshot() -> MSState {
                MSState(
                    minTime: s.minTime(), maxTime: s.maxTime(), nextAt: s.nextAt,
                    headCount: s.headChunkCount, firstChunkID: s.firstChunkID.rawValue,
                    lastValue: hbits(s.lastValue),
                    hasLastHistogram: z(s.lastHistogramValue != nil),
                    hasLastFloatHistogram: z(s.lastFloatHistogramValue != nil),
                    hasApp: s.app != nil,
                    headChunks: collectHeadChunks(s.headChunks).map {
                        MSChunkState(
                            minTime: $0.minTime, maxTime: $0.maxTime,
                            encoding: $0.chunk.encoding.rawValue,
                            numSamples: $0.chunk.numSamples, bytes: hex($0.chunk.bytes))
                    },
                    mmappedChunks: s.mmappedChunks.map {
                        MSMmappedState(
                            ref: $0.ref.rawValue, numSamples: $0.numSamples,
                            minTime: $0.minTime, maxTime: $0.maxTime)
                    },
                    txIDs: s.txs.map { ring in
                        var it = ring.iterator()
                        var ids: [UInt64] = []
                        for _ in 0..<ring.count {
                            ids.append(it.at())
                            it.next()
                        }
                        return ids
                    } ?? [],
                    hasTxRing: s.txs != nil)
            }

            var out = MSOut(ops: [], states: [], files: [])
            for op in input.ops {
                var r = MSOpOut(
                    sampleInOrder: nil, chunkCreated: nil, isOOO: nil, oooDelta: nil, err: nil,
                    count: nil, found: nil, minTime: nil, overlaps: nil)
                switch op.op {
                case "append":
                    let (inOrder, created) = s.append(
                        st: op.st ?? 0, t: op.t ?? 0, v: fbits(op.v ?? "0000000000000000"),
                        appendID: op.appendID ?? 0, o: o)
                    r.sampleInOrder = z(inOrder)
                    r.chunkCreated = z(created)
                case "appendable":
                    let (isOOO, delta, err) = s.appendable(
                        t: op.t ?? 0, v: fbits(op.v ?? "0000000000000000"),
                        headMaxt: op.headMaxt ?? 0, minValidTime: op.minValidTime ?? 0,
                        oooTimeWindow: op.oooTimeWindow ?? 0)
                    r.isOOO = z(isOOO)
                    r.oooDelta = z(delta)
                    r.err = z(err.map { String(describing: $0) } ?? "")
                case "mmapChunks":
                    r.count = z(s.mmapChunks(chunkDiskMapper: cdm))
                case "truncateChunksBefore":
                    r.count = z(s.truncateChunksBefore(mint: op.mint ?? 0))
                case "cleanupAppendIDsBelow":
                    s.cleanupAppendIDsBelow(op.bound ?? 0)
                case "atOffset":
                    if let head = s.headChunks, let c = head.atOffset(op.offset ?? 0) {
                        r.found = true
                        r.minTime = z(c.minTime)
                    }
                case "overlapsHead":
                    if let head = s.headChunks {
                        r.overlaps = z(
                            head.overlapsClosedInterval(op.mint ?? 0, op.maxt ?? 0))
                    }
                case "forceLastHistogram":
                    // The probe's affordance for a field only the deferred histogram append path sets.
                    s.lastHistogramValue = Histogram()
                case "forceLastFloatHistogram":
                    s.lastFloatHistogramValue = FloatHistogram()
                case "snapshot":
                    out.states.append(snapshot())
                    continue
                case "setOpts":
                    if let u = op.useXOR2 { o.useXOR2 = u }
                    if let st = op.storeST { o.storeST = st }
                    continue
                case "seedMmapped":
                    // What `loadMmappedChunks` does on WAL replay (§7h), and the only route to a series with
                    // mmapped chunks and no head chunk.
                    for m in op.mmapped ?? [] {
                        s.mmappedChunks.append(
                            MmappedChunk(
                                ref: ChunkDiskMapperRef(rawValue: m.ref), numSamples: m.numSamples,
                                minTime: m.minTime, maxTime: m.maxTime))
                    }
                    continue
                default:
                    Issue.record("unknown memseries op \(op.op)")
                    continue
                }
                out.ops.append(r)
            }
            out.states.append(snapshot())
            try cdm.close()
            for name in ((try? fs.list("chunks_head")) ?? []).sorted() {
                guard let h = try? fs.openForReading("chunks_head/\(name)"),
                    let bytes = try? h.read(offset: 0, length: h.size)
                else { continue }
                try? h.close()
                out.files.append(
                    MSFileState(name: name, size: bytes.count, bytes: rleHex(bytes)))
            }
            return out
        }
    }
}
