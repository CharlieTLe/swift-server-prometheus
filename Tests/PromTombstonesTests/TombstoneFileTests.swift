//===----------------------------------------------------------------------===//
// The tombstone FILE, both directions, against `Fixtures/tombstones/file.jsonl`.
//
// The corpus commits the BYTES `WriteFile` produced, not just the intervals that came back, and that one
// equality is what covers both directions of the round trip: Go wrote these bytes and read them back, so a
// port that produces the same bytes for the same input is a port upstream can read. See
// `oracle/suites_tombstone_file.go` for the argument in full and for why the `Reader` the corpus hands
// `Encode` is ordered.
//
// What is asserted here rather than in the corpus is at the bottom: the error strings a `PromFS` failure
// produces, which have no upstream counterpart because upstream's are `*os.PathError`s carrying a temporary
// directory's name.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromFS
import PromStorage
import Testing

@testable import PromTombstones

// MARK: - Wire types

struct TSAdd: Codable, Sendable {
    var ref: UInt64
    var mint: Int64
    var maxt: Int64
}

struct TSEntry: Codable, Equatable, Sendable {
    var ref: UInt64
    var intervals: [[Int64]]
}

struct TSFileIn: Codable, Sendable {
    var adds: [TSAdd]?
    var probes: [UInt64]
    var iterFailsAfter: Int
}

struct TSFileOut: Codable, Equatable, Sendable {
    var encoded: String
    var encodeErr: String
    var file: String
    var size: Int64
    var writeErr: String
    var dirents: [String]
    var readEntries: [TSEntry]
    var readTotal: UInt64
    var readSize: Int64
    var readErr: String
    var decodeEntries: [TSEntry]
    var decodeTotal: UInt64
    var decodeErr: String
    var probed: [[[Int64]]]
}

// MARK: - Helpers shared with the corruption suite

/// The oracle's `errIterFailed`. The text is load-bearing: `WriteFile` wraps it as
/// `encoding tombstones: iter failed`, so a different message is a fixture diff.
struct IterFailed: Error, CustomStringConvertible {
    var description: String { "iter failed" }
}

/// The oracle's `orderedTombstones`, minus the sorting — `MemTombstones.iter` is already ascending by ref
/// (PORTING.md exception 29), which is the whole point of that exception. All this adds is the failure.
struct FailAfterReader: TombstoneReader {
    let inner: MemTombstones
    /// -1 never fails.
    let failAfter: Int

    func get(_ ref: SeriesRef) throws -> [DeletionInterval] { try inner.get(ref) }

    func iter(_ f: (SeriesRef, [DeletionInterval]) throws -> Void) throws {
        var i = 0
        try inner.iter { ref, ivs in
            // Checked BEFORE the callback, as the oracle's loop is: `failAfter: 0` emits nothing at all.
            if failAfter >= 0 && i >= failAfter { throw IterFailed() }
            i += 1
            try f(ref, ivs)
        }
    }

    func total() -> UInt64 { inner.total() }
    func close() throws {}
}

func tsFlatten(_ tr: MemTombstones) -> [TSEntry] {
    var out: [TSEntry] = []
    try? tr.iter { ref, ivs in
        out.append(TSEntry(ref: ref.rawValue, intervals: ivs.map { [$0.mint, $0.maxt] }))
    }
    return out.sorted { $0.ref < $1.ref }
}

func tsErrString(_ e: (any Error)?) -> String {
    guard let e else { return "" }
    return "\(e)"
}

// MARK: - The suite

@Suite("tombstones: the file codec, both directions")
struct TombstoneFileTests {

    @Test("every committed round-trip case matches Go")
    func matchesGo() throws {
        try Fixtures.check("tombstones/file.jsonl", FixtureCase<TSFileIn, TSFileOut>.self) { input in
            let fs = InMemoryFS()
            let dir = "block"
            try fs.createDirectory(dir)

            let mem = MemTombstones()
            for a in input.adds ?? [] {
                mem.addInterval(
                    SeriesRef(rawValue: a.ref), DeletionInterval(mint: a.mint, maxt: a.maxt))
            }
            let tr = FailAfterReader(inner: mem, failAfter: input.iterFailsAfter)

            var out = TSFileOut(
                encoded: "", encodeErr: "", file: "", size: 0, writeErr: "", dirents: [],
                readEntries: [], readTotal: 0, readSize: 0, readErr: "", decodeEntries: [],
                decodeTotal: 0, decodeErr: "", probed: [])

            let (encoded, encodeError) = encodeTombstones(tr)
            out.encoded = Hex.encode(encoded)
            out.encodeErr = tsErrString(encodeError)

            do {
                out.size = try writeTombstoneFile(fs, dir, tr)
            } catch {
                out.writeErr = "\(error)"
            }

            if let h = try? fs.openForReading("\(dir)/\(tombstonesFilename)") {
                out.file = Hex.encode(try h.read(offset: 0, length: h.size))
                try h.close()
            }
            out.dirents = (try? fs.list(dir)) ?? []

            do {
                let (readBack, readSize) = try readTombstones(fs, dir)
                out.readSize = readSize
                out.readTotal = readBack.total()
                out.readEntries = tsFlatten(readBack)
                for p in input.probes {
                    let ivs = try readBack.get(SeriesRef(rawValue: p))
                    out.probed.append(ivs.map { [$0.mint, $0.maxt] })
                }
            } catch {
                out.readErr = "\(error)"
            }

            do {
                let decoded = try decodeTombstones(encoded)
                out.decodeTotal = decoded.total()
                out.decodeEntries = tsFlatten(decoded)
            } catch {
                out.decodeErr = "\(error)"
            }

            return out
        }
    }

    // MARK: - What the corpus cannot carry

    /// Upstream's failure here is `open /tmp/xxxx/tombstones.tmp: no such file or directory` — a
    /// `*os.PathError` naming a temporary directory, so its text cannot be committed. What IS worth pinning
    /// is that the failure happens at `createFile` and leaves nothing behind, which is `PromFS`' contract
    /// rather than Go's.
    @Test("a write into a directory that does not exist fails and leaves nothing")
    func writeIntoMissingDirectory() throws {
        let fs = InMemoryFS()
        #expect(throws: FSError.self) {
            try writeTombstoneFile(fs, "nope", MemTombstones())
        }
        #expect(!fs.exists("nope/tombstones"))
        #expect(!fs.exists("nope/tombstones.tmp"))
    }

    /// The temporary file is removed on the failing path too, which is upstream's unconditional `defer`.
    /// The corpus sees this as an empty `dirents`, but only for a failure of `Encode`; this reaches the
    /// same `defer` through a failure that happens *after* bytes were written to the temporary file.
    @Test("the temporary file never survives a failed write")
    func temporaryFileIsAlwaysRemoved() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("block")
        let mem = MemTombstones()
        mem.addInterval(SeriesRef(rawValue: 1), DeletionInterval(mint: 1, maxt: 2))
        mem.addInterval(SeriesRef(rawValue: 2), DeletionInterval(mint: 3, maxt: 4))
        // Fails on the SECOND entry, so the version byte and the first triple are already in the buffer.
        #expect(throws: TombstoneFileError.self) {
            try writeTombstoneFile(fs, "block", FailAfterReader(inner: mem, failAfter: 1))
        }
        #expect(try fs.list("block") == [])
    }

    /// `Encode` hands back the partial buffer alongside the error, which is Go's `return buf.Get(), err`.
    /// The corpus pins the bytes; this pins that the port's signature can express them at all, because a
    /// `throws` version would compile and silently drop them.
    @Test("Encode returns the partial buffer with its error")
    func encodeReturnsPartialBuffer() throws {
        let mem = MemTombstones()
        mem.addInterval(SeriesRef(rawValue: 1), DeletionInterval(mint: 1, maxt: 2))
        mem.addInterval(SeriesRef(rawValue: 2), DeletionInterval(mint: 3, maxt: 4))
        let (bytes, error) = encodeTombstones(FailAfterReader(inner: mem, failAfter: 1))
        #expect(error is IterFailed)
        // The version byte and the first entry's triple: 01 | uvarint(1) varint(1) varint(2).
        #expect(Hex.encode(bytes) == "01010204")
    }

    /// Exception 29, asserted directly rather than inferred from the file's bytes: the port's `Iter` is
    /// ascending by ref where upstream's ranges a map. Insertion order here is deliberately hostile.
    @Test("MemTombstones.iter is ascending by ref")
    func iterIsOrdered() throws {
        let mem = MemTombstones()
        for ref in [UInt64(9), 1, 300, 0, 42, 7] {
            mem.addInterval(SeriesRef(rawValue: ref), DeletionInterval(mint: 1, maxt: 2))
        }
        var seen: [UInt64] = []
        try mem.iter { ref, _ in seen.append(ref.rawValue) }
        #expect(seen == [0, 1, 7, 9, 42, 300])
    }

    /// The empty file is what `compact.go:739` writes for every block with no deletions, so it is worth
    /// spelling out once: nine bytes, and the last four are the CRC-32C of nothing, which is zero.
    @Test("the empty file is nine bytes")
    func emptyFileLayout() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("block")
        let size = try writeTombstoneFile(fs, "block", MemTombstones())
        #expect(size == 9)
        let h = try fs.openForReading("block/tombstones")
        #expect(Hex.encode(try h.read(offset: 0, length: h.size)) == "0130ba300100000000")
        try h.close()
    }

    /// `Block.Delete` writes the whole file again on every call, so the second write must REPLACE the first
    /// rather than append to it. Upstream gets that from `fileutil.Replace`'s rename; the port gets it from
    /// `createFile`'s `O_TRUNC` on both the temporary file and its destination. The corpus writes once per
    /// case and so cannot see it, and the failure mode — a file that grows and whose trailing four bytes are
    /// still a valid CRC of a *prefix* — would read as corruption rather than as a bug here.
    @Test("a second write replaces the file rather than appending to it")
    func secondWriteReplaces() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("block")

        let wide = MemTombstones()
        for ref in UInt64(1)...UInt64(20) {
            wide.addInterval(
                SeriesRef(rawValue: ref), DeletionInterval(mint: Int64(ref), maxt: Int64(ref) * 2))
        }
        let bigSize = try writeTombstoneFile(fs, "block", wide)
        #expect(bigSize > 9)

        let smallSize = try writeTombstoneFile(fs, "block", MemTombstones())
        #expect(smallSize == 9)
        let (readBack, fileSize) = try readTombstones(fs, "block")
        #expect(fileSize == 9)
        #expect(readBack.total() == 0)
        #expect(try fs.list("block") == ["tombstones"])
    }

    /// A `tombstones` entry that is a DIRECTORY is an error, not "no tombstones". Upstream's arm is
    /// `os.IsNotExist(err)` specifically, so EISDIR falls through to `return nil, 0, err` — a port that
    /// spelled the check as "anything that failed to open means no deletions" would silently ignore a
    /// block's tombstones, which is the exact failure exception 16 describes.
    @Test("a tombstones path that is a directory is an error, not an empty reader")
    func directoryIsAnError() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("block/tombstones")
        #expect(throws: FSError.isADirectory("block/tombstones")) {
            _ = try readTombstones(fs, "block")
        }
    }
}
