//===----------------------------------------------------------------------===//
// `tsdb/wlog`'s reader against BYTES rather than against its own writer.
//
// `WALSegmentTests` drives a write program and reads the result back, which means every byte the reader sees
// is well-formed by construction. That left nine of the sweep's 22 survivors untestable — the CRC check, the
// length bound, all four arms of `validateRecord`, the padding check and the two EOFs could each be deleted
// outright without failing a case.
//
// This suite's input is a **fragment list**: a raw type byte, a payload, and optional overrides of the length
// and CRC fields, plus an optional truncation of the assembled stream. See `oracle/suites_wal_corrupt.go` for
// why that shape is necessary and what each case reaches.
//
// **The one counter-intuitive behaviour, pinned rather than assumed:** a truncated segment does not end the
// stream. `SegmentBufReader` fakes zero padding to the page boundary so it does not advance `cur` and blame
// the wrong file, so the reader sees a *page terminator* — which overwrites `curRecTyp` and therefore erases
// the evidence `Next`'s torn-record check looks for. A `first` fragment alone reports **no error at all**;
// only a page-ALIGNED cut answers `last record is torn`.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromFS
import PromHash
import Testing

// `readFull` is internal to `PromWAL` — it is a free function below the `Reader`, and the two arms it
// distinguishes are exactly what this suite has to reach directly.
@testable import PromWAL

// MARK: - Wire types

/// One hand-written fragment. `type` is the RAW header byte, so an invalid type or a flag bit is
/// expressible; `lenOverride` and `crcOverride` are -1 for "use the real value".
struct WALFrag: Codable, Sendable {
    var type: UInt8
    var payload: String
    var lenOverride: Int
    var crcOverride: Int64
    var pageTerm: Bool
    var padZeros: Int
    var padDirty: Bool
}

struct WALCorruptIn: Codable, Sendable {
    var frags: [WALFrag]?
    var truncateTo: Int
}

/// The oracle's `walEncodeFrags`. Kept as a mirror rather than shared with the writer on purpose: the point
/// of this corpus is bytes the writer would never produce.
func walEncodeFrags(_ frags: [WALFrag]) -> [UInt8] {
    var buf: [UInt8] = []
    for f in frags {
        if f.pageTerm {
            buf.append(f.type)
            var pad = [UInt8](repeating: 0, count: f.padZeros)
            if f.padDirty && f.padZeros > 0 {
                pad[f.padZeros - 1] = 1
            }
            buf.append(contentsOf: pad)
            continue
        }
        let payload = unrleHex(f.payload)
        var hdr = [UInt8](repeating: 0, count: recordHeaderSize)
        hdr[0] = f.type

        let length = f.lenOverride >= 0 ? f.lenOverride : payload.count
        hdr[1] = UInt8(truncatingIfNeeded: length >> 8)
        hdr[2] = UInt8(truncatingIfNeeded: length)

        let crc = f.crcOverride >= 0 ? UInt32(truncatingIfNeeded: f.crcOverride) : CRC32C.checksum(payload)
        hdr[3] = UInt8(truncatingIfNeeded: crc >> 24)
        hdr[4] = UInt8(truncatingIfNeeded: crc >> 16)
        hdr[5] = UInt8(truncatingIfNeeded: crc >> 8)
        hdr[6] = UInt8(truncatingIfNeeded: crc)

        buf.append(contentsOf: hdr)
        buf.append(contentsOf: payload)
    }
    return buf
}

@Suite("wal: the reader against corrupt and truncated bytes")
struct WALCorruptTests {

    @Test("every committed corruption case matches Go")
    func matchesGo() throws {
        try Fixtures.check("wal/corrupt.jsonl", FixtureCase<WALCorruptIn, WALOut>.self) { input in
            let fs = InMemoryFS()
            let dir = "wal"
            try fs.createDirectory(dir)

            var bytes = walEncodeFrags(input.frags ?? [])
            if input.truncateTo >= 0 && input.truncateTo < bytes.count {
                bytes = Array(bytes[0..<input.truncateTo])
            }
            let h = try fs.createFile("\(dir)/00000000")
            try h.append(bytes)
            try h.close()

            var out = WALOut(
                segments: [], segFirst: 0, segLast: 0, size: 0, lastSegment: 0, lastOffset: 0,
                opErr: "", read: [], readErr: "", readSegment: 0, readOffset: 0,
                readerHasNoSegments: false)

            // The same read-back the write-program suite uses, because the oracle shares one too — the
            // write-side fields simply stay at zero, since nothing was logged through a `WL`.
            walReadBack(fs, dir, readFirst: -1, readLast: -1, &out)
            return out
        }
    }

    // MARK: - The declared divergence: a compressed record

    /// **Exception 20.** The corpus cannot carry these three cases, because upstream does not merely notice
    /// the compression flag — it *decompresses*, and answers `snappy: corrupt input` for the snappy bit and
    /// `unexpected EOF` for the zstd one on a payload that is not a valid frame in either codec. The port
    /// rejects the record by name instead, which is a **declared** divergence rather than a defect, so
    /// pinning it differentially would pin a disagreement the port is documented to have.
    ///
    /// What matters is that the rejection is at the record and names the codec, rather than the flag being
    /// ignored and the payload handed back as if it were plain — that would be silent data corruption.
    @Test("a record carrying a compression flag is rejected by name, not misread")
    func compressedRecordIsRejected() throws {
        for (flag, name) in [(UInt8(0x08), "snappy"), (UInt8(0x10), "zstd"), (UInt8(0x18), "snappy")] {
            let fs = InMemoryFS()
            try fs.createDirectory("wal")
            let frag = WALFrag(
                type: WALRecordType.full.rawValue | flag, payload: "010203",
                lenOverride: -1, crcOverride: -1, pageTerm: false, padZeros: 0, padDirty: false)
            let h = try fs.createFile("wal/00000000")
            try h.append(walEncodeFrags([frag]))
            try h.close()

            let sr = try newWALSegmentsReader(fs, "wal")
            let r = WALReader(sr)
            #expect(r.next() == false)
            // Both flags set reads as snappy, because the reader tests snappy first.
            let msg = r.err.map { String(describing: $0) } ?? ""
            #expect(msg.contains("unsupported compression type: \(name)"))
            try sr.close()
        }
    }

    // MARK: - readFull's two arms, which no segment file can reach

    /// `readFull` distinguishes `io.EOF` (nothing read — a clean end) from `io.ErrUnexpectedEOF` (a partial
    /// read — a corruption), and that distinction is the whole of `Reader.Next`'s control flow. A segment
    /// file cannot exercise it: `SegmentBufReader` pads a short segment with zeros to the page boundary, so
    /// the reader is never handed a partial read at all.
    ///
    /// So the two arms are asserted against a bare `WALByteReader` — one level below the segment machinery,
    /// the same drop-a-level move `MatrixIterSliceTests` makes when the querier absorbs the behaviour.
    @Test("readFull separates a clean end from a partial read")
    func readFullArms() throws {
        /// Hands out `bytes` and then ends, with no page padding of any kind.
        final class RawReader: WALByteReader {
            var bytes: [UInt8]
            var pos = 0
            init(_ b: [UInt8]) { bytes = b }
            func read(into dst: inout [UInt8], _ range: Range<Int>) throws -> Int? {
                if pos >= bytes.count { return nil }
                let n = min(range.count, bytes.count - pos)
                for k in 0..<n { dst[range.lowerBound + k] = bytes[pos + k] }
                pos += n
                return n
            }
            func close() throws {}
        }

        var buf = [UInt8](repeating: 0, count: pageSize)

        // Nothing at all: a clean end, spelled nil.
        let empty = RawReader([])
        #expect(try readFull(empty, &buf, 0..<4) == nil)

        // Fewer bytes than asked for: a PARTIAL read, which is a corruption and not an end.
        let partial = RawReader([1, 2])
        #expect(throws: WALError.unexpectedEOF) { _ = try readFull(partial, &buf, 0..<4) }

        // Exactly as many as asked for: no error, and the count comes back.
        let exact = RawReader([1, 2, 3, 4])
        #expect(try readFull(exact, &buf, 0..<4) == 4)

        // And the torn-record check, which the padding emulation erases for a real segment: a `first`
        // fragment followed by a clean end is `last record is torn`.
        let frag = WALFrag(
            type: WALRecordType.first.rawValue, payload: "0102",
            lenOverride: -1, crcOverride: -1, pageTerm: false, padZeros: 0, padDirty: false)
        let r = WALReader(RawReader(walEncodeFrags([frag])))
        #expect(r.next() == false)
        #expect(r.err != nil)
        #expect(String(describing: r.err!).contains("last record is torn"))
        // Not a `SegmentBufReader`, so `Err()` takes the other spelling: no segment to name.
        #expect(r.segment == -1)
    }
}
