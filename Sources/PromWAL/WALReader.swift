//===----------------------------------------------------------------------===//
// Ported from tsdb/wlog/reader.go and the reader half of wlog.go @ v3.13.2.
//
// ## `io.EOF` and `io.ErrUnexpectedEOF` are different answers, and the whole control flow turns on it
//
// `Reader.Next` swallows exactly one error — `errors.Is(err, io.EOF)` — and reports everything else. Go's
// `io.ReadFull` returns `io.EOF` only when it read **nothing**, and `io.ErrUnexpectedEOF` when it read some
// but not all. So:
//
//   * a stream that ends exactly on a fragment boundary ends cleanly;
//   * a stream that ends *inside* a header or payload is a **corruption**, reported as
//     `read remaining header: unexpected EOF`;
//   * and a clean end after a `first` or `middle` fragment is still an error — `last record is torn` —
//     because `curRecTyp` survives the loop and `Next` checks it on the way out.
//
// A port that collapsed the two EOFs would turn the second case into silence, which is the difference
// between detecting a torn write and replaying half a record.
//
// ## The page terminator's zero count is checked against the PAGE, not the record
//
//     k := pageSize - (r.total % pageSize)
//     if k == pageSize { continue }     // the initial 0 byte WAS the last byte of the page
//
// `total` has already been incremented for the type byte, so `k` is how many bytes remain in the page after
// it. The `k == pageSize` case is the terminator sitting in the page's final byte, where there is nothing
// left to verify. Everything else must be zeros, and a non-zero byte in the padding is an error rather than
// a resynchronisation point — a WAL is read from the start or not at all.
//
// ## `SegmentBufReader` fakes the padding of a short segment rather than moving on
//
// When a segment's bytes run out mid-page it returns **zeros** up to the page boundary and does not advance
// `cur`. Upstream's comment says why: `cur` is what `Reader.Err()` reports as the corrupt segment, so
// advancing early would blame the wrong file. The consequence for the reader above is that a short final
// segment looks exactly like a padded one.
//
// `bufio.Reader` is dropped. It is pure buffering — `Reader` reads through `io.ReadFull`, which loops until
// filled, so a short read is invisible — and ADR-15 has already read the whole segment into memory, so
// there is nothing left to buffer.
//===----------------------------------------------------------------------===//

public import PromFS

/// Go: `io.Reader`, as much of it as the WAL reader needs.
///
/// `read` returns the number of bytes placed at `dst[range.lowerBound...]`, or **nil for `io.EOF`**. Nil
/// rather than an error case because the distinction from a short read is the whole point — see the file
/// header — and an optional makes it impossible to conflate the two by accident.
public protocol WALByteReader: AnyObject {
    func read(into dst: inout [UInt8], _ range: Range<Int>) throws -> Int?
    func close() throws
}

/// Go: `io.ReadFull`.
///
/// Returns nil for `io.EOF` (nothing read at all) and throws ``WALError/unexpectedEOF`` for a partial read.
/// Reproduced rather than expressed as "fill or fail" because those are the two outcomes `Reader.Next`
/// distinguishes.
///
/// **A read of 0 bytes with no error is a RETRY, not an end.** `io.ReadAtLeast`'s loop is
/// `for n < min && err == nil`, so a `(0, nil)` return just goes round again — and `SegmentBufReader` returns
/// exactly that when it advances to the next segment. Treating 0 as EOF made the reader stop after the first
/// segment of every multi-segment WAL, which is what the corpus caught.
func readFull(
    _ r: any WALByteReader, _ dst: inout [UInt8], _ range: Range<Int>
) throws -> Int? {
    var n = 0
    while n < range.count {
        guard let got = try r.read(into: &dst, (range.lowerBound + n)..<range.upperBound) else {
            if n == 0 { return nil }
            throw WALError.unexpectedEOF
        }
        n += got
    }
    return n
}

/// Go: `wlog.Reader`.
public final class WALReader {

    private let rdr: any WALByteReader
    private var error: (any Error)?
    private var rec: [UInt8] = []

    private var precomprBuf: [UInt8] = []
    private var buf = [UInt8](repeating: 0, count: pageSize)
    /// Go: `total` — bytes processed, and the divisor for the page-boundary check.
    private var total: Int64 = 0
    /// Go: `curRecTyp` — kept across `nextNew` calls so `Next` can detect a torn last record.
    private var curRecTyp = WALRecordType.pageTerm

    public init(_ r: any WALByteReader) {
        self.rdr = r
    }

    /// Go: `Record()`. Valid only until the next `next()`.
    public var record: [UInt8] { rec }

    /// Go: `Next()`. **Must not be called again after it returns false.**
    public func next() -> Bool {
        do {
            try nextNew()
            error = nil
            return true
        } catch let e {
            if let we = e as? WALError, we.isEOF {
                // A clean end is only clean if the last fragment completed a record.
                if curRecTyp == .first || curRecTyp == .middle {
                    error = WALError.lastRecordIsTorn
                }
                return false
            }
            error = e
            return false
        }
    }

    /// Go: `nextNew`.
    private func nextNew() throws {
        precomprBuf.removeAll(keepingCapacity: true)

        var i = 0
        while true {
            // The header's first byte on its own, because the page terminator is a one-byte record.
            guard try readFull(rdr, &buf, 0..<1) != nil else {
                throw WALError.wrapped("read first header byte", WALError.eof)
            }
            total += 1
            curRecTyp = walRecordType(fromHeader: buf[0])

            var compr = WALCompression.none
            if buf[0] & snappyMask == snappyMask {
                compr = .snappy
            } else if buf[0] & zstdMask == zstdMask {
                compr = .zstd
            }

            if curRecTyp == .pageTerm {
                // `total` already counts the type byte, so `k` is what is left of THIS page.
                let k = Int(Int64(pageSize) - (total % Int64(pageSize)))
                if k == pageSize {
                    continue  // the terminator was the page's last byte
                }
                // Go resizes `buf` to `r.buf[1:]` here, because a terminator in the page's first byte
                // needs `pageSize-1` bytes of room. The port's buffer is `pageSize` long and it reads
                // into `1..<1+k`, which is the same span.
                guard let n = try readFull(rdr, &buf, 1..<(1 + k)) else {
                    throw WALError.wrapped("read remaining zeros", WALError.eof)
                }
                total += Int64(n)
                for c in buf[1..<(1 + k)] where c != 0 {
                    throw WALError.unexpectedNonZeroByteInPaddedPage
                }
                continue
            }

            guard let hn = try readFull(rdr, &buf, 1..<recordHeaderSize) else {
                throw WALError.wrapped("read remaining header", WALError.eof)
            }
            total += Int64(hn)

            let length = (UInt16(buf[1]) << 8) | UInt16(buf[2])
            var crc: UInt32 = 0
            for k in 3..<7 { crc = (crc << 8) | UInt32(buf[k]) }

            if Int(length) > pageSize - recordHeaderSize {
                throw WALError.invalidRecordSize(length)
            }
            // Go reads into `buf` — which is `r.buf[recordHeaderSize:]`, a WINDOW past the header — so the
            // payload lands at offset 7 of the page buffer and cannot overwrite the header it is being
            // checked against.
            let payload = recordHeaderSize..<(recordHeaderSize + Int(length))
            var n = 0
            if length > 0 {
                guard let got = try readFull(rdr, &buf, payload) else { throw WALError.eof }
                n = got
            }
            total += Int64(n)

            if n != Int(length) {
                throw WALError.invalidSize(expected: Int(length), got: n)
            }
            let c = walCRC(buf[payload])
            if c != crc {
                throw WALError.unexpectedChecksum(got: c, expected: crc)
            }
            try validateRecord(curRecTyp, i)

            precomprBuf.append(contentsOf: buf[payload])
            if curRecTyp == .last || curRecTyp == .full {
                if compr != .none {
                    throw WALError.unsupportedCompressionType(compr.rawValue)
                }
                rec = precomprBuf
                return
            }

            // Only content fragments advance `i`; a page terminator does not, which is what lets a record
            // cross a page boundary.
            i += 1
        }
    }

    /// Go: `Err()` — the last error, wrapped as a `CorruptionErr`.
    ///
    /// The segment and offset come from the source if it is a `SegmentBufReader` and are `-1` and the
    /// stream total otherwise, which is the two-spelling distinction `WALCorruptionError` documents.
    public var err: (any Error)? {
        guard let e = error else { return nil }
        if let b = rdr as? SegmentBufReader, let cur = b.currentSegment {
            return WALCorruptionError(
                dir: cur.dir, segment: cur.index, offset: Int64(b.off), underlying: e)
        }
        return WALCorruptionError(segment: -1, offset: total, underlying: e)
    }

    /// Go: `Segment()` — `-1` when the source cannot say.
    public var segment: Int {
        (rdr as? SegmentBufReader)?.currentSegment?.index ?? -1
    }

    /// Go: `Offset()`.
    public var offset: Int64 {
        if let b = rdr as? SegmentBufReader { return Int64(b.off) }
        return total
    }
}

// MARK: - SegmentBufReader

/// Go: `wlog.segmentBufReader`.
///
/// Unexported upstream, and exported here because `Reader.Err()` type-tests for it and the corpus has to be
/// able to build one. Nothing else about it is different.
public final class SegmentBufReader: WALByteReader {

    var segs: [WALSegment]
    var cur = 0
    /// Go: `off` — the offset **into the current segment**, reset on each advance. Not a stream total.
    var off = 0

    /// Go: `NewSegmentBufReader`.
    public init(_ segs: [WALSegment]) {
        self.segs = segs
    }

    /// Go: `NewSegmentBufReaderWithOffset` — discards `offset` bytes of the first segment.
    public init(offset: Int, segs: [WALSegment]) {
        self.segs = segs
        if offset > 0 && !segs.isEmpty {
            let seg = segs[0]
            let d = min(offset, seg.readBytes.count - seg.readOffset)
            seg.readOffset += d
            // `bufio.Discard` advances the buffered reader without touching `off`, and so does this: the
            // caller passed an offset it already knows about.
        }
    }

    var currentSegment: WALSegment? {
        segs.indices.contains(cur) ? segs[cur] : nil
    }

    public func read(into dst: inout [UInt8], _ range: Range<Int>) throws -> Int? {
        if segs.isEmpty { return nil }

        let seg = segs[cur]
        var n = 0
        let available = seg.readBytes.count - seg.readOffset
        if available > 0 {
            n = min(range.count, available)
            for k in 0..<n {
                dst[range.lowerBound + k] = seg.readBytes[seg.readOffset + k]
            }
            seg.readOffset += n
            off += n
            return n
        }

        // Hit the end of this segment's bytes.
        //
        // If it is not page-aligned, fake the zero padding and DO NOT advance `cur` — upstream's comment
        // says why: `cur` is what `Reader.Err()` blames, so advancing early names the wrong file.
        if off % pageSize != 0 {
            var i = 0
            while n + i < range.count && (off + i) % pageSize != 0 {
                dst[range.lowerBound + n + i] = 0
                i += 1
            }
            off += i
            // Returns early even without filling `dst`, which is legal for `io.Reader` and is why
            // `readFull` has to loop.
            return n + i
        }

        if cur + 1 >= segs.count { return nil }

        cur += 1
        off = 0
        return n
    }

    public func close() throws {
        var first: (any Error)?
        for s in segs {
            do { try s.close() } catch { first = error }
        }
        if let e = first { throw e }
    }
}

/// Go: `wlog.SegmentRange`. `-1` on either end means open.
public struct WALSegmentRange: Sendable {
    public var dir: String
    public var first: Int
    public var last: Int

    public init(dir: String, first: Int = -1, last: Int = -1) {
        self.dir = dir
        self.first = first
        self.last = last
    }
}

/// Go: `wlog.NewSegmentsReader`.
public func newWALSegmentsReader(_ fs: any PromFS, _ dir: String) throws -> SegmentBufReader {
    try newWALSegmentsRangeReader(fs, [WALSegmentRange(dir: dir)])
}

/// Go: `wlog.NewSegmentsRangeReader`.
///
/// Note the asymmetry between the two bounds: `first` **continues** past an out-of-range index while `last`
/// **breaks**. That is only equivalent to a filter because `listSegments` returns them sorted.
///
/// Both failure paths are WRAPPED, and the exact spelling matters because `Reader`'s callers surface it:
/// `list segment in dir:%v: %w` and `open segment:%v in dir:%v: %w` — note there is no space after either
/// colon. The port originally returned the bare underlying error and the pre-seeded gap case caught it.
public func newWALSegmentsRangeReader(
    _ fs: any PromFS, _ ranges: [WALSegmentRange]
) throws -> SegmentBufReader {
    var segs: [WALSegment] = []
    for r in ranges {
        let refs: [WALSegmentRef]
        do {
            refs = try listWALSegments(fs, r.dir)
        } catch {
            throw WALError.wrapped("list segment in dir:\(r.dir)", error)
        }
        for ref in refs {
            if r.first >= 0 && ref.index < r.first { continue }
            if r.last >= 0 && ref.index > r.last { break }
            do {
                segs.append(try openReadWALSegment(fs, "\(r.dir)/\(ref.name)"))
            } catch {
                throw WALError.wrapped("open segment:\(ref.name) in dir:\(r.dir)", error)
            }
        }
    }
    return SegmentBufReader(segs)
}
