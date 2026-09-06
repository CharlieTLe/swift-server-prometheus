//===----------------------------------------------------------------------===//
// `ReadTombstones` and `Decode` against BYTES rather than against their own writer.
//
// `TombstoneFileTests` drives a round trip, so every byte the reader sees was produced by `WriteFile` one
// call earlier and every validation in the reader is unreachable — the header guard, the magic, the CRC and
// the format byte could each be deleted outright and nothing would fail. That is §7c's lesson restated: a
// write program cannot express "one bit flipped".
//
// This suite's input is a **file description** instead — magic, version byte, body and CRC as four
// independently overridable or omittable parts, plus a trailer and a truncation. See
// `oracle/suites_tombstone_corrupt.go` for what each family reaches.
//
// **The counter-intuitive behaviour, pinned rather than assumed:** an 8-byte file PANICS upstream
// (`runtime error: slice bounds out of range [1:0]`, quirk 210), a corrupted VERSION byte still passes the
// checksum (quirk 211), and a 5-to-7-byte file reports `invalid magic number 0` rather than a size error
// (quirk 212). The port raises the panic as an error carrying Go's text, so the harness sorts a thrown
// error into `err` or `panic` by its `runtime error: ` prefix.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromFS
import PromHash
import PromStorage
import Testing

@testable import PromTombstones

// MARK: - Wire types

struct TSCorruptIn: Codable, Sendable {
    var absent: Bool
    var magic: Int64
    var version: Int
    var body: String?
    var crc: Int64
    var trailer: String?
    var truncateTo: Int
}

struct TSCorruptOut: Codable, Equatable, Sendable {
    var file: String
    var err: String
    var panic: String
    var size: Int64
    var total: UInt64
    var entries: [TSEntry]
    var decodeErr: String
    var decodePanic: String
    var decodeTotal: UInt64
    var decodeEntries: [TSEntry]
}

/// The oracle's sentinels. -1 is "the correct value", -2 is "omit these bytes".
private let tsKeep: Int64 = -1
private let tsOmit: Int64 = -2

/// The oracle's `tsAssemble`, mirrored. Kept as a mirror rather than shared with `writeTombstoneFile` on
/// purpose: the point of this corpus is bytes the writer would never produce.
///
/// The two BE32 fields are written as four stepwise statements rather than a loop over a computed shift —
/// HANDOFF §4: a chained/computed shift expression is where the Swift 6.1 floor's type checker gives out,
/// and it costs nothing to spell out here.
func tsAssemble(_ input: TSCorruptIn) -> [UInt8] {
    let body = Hex.decode(input.body ?? "")
    let trailer = Hex.decode(input.trailer ?? "")

    var buf: [UInt8] = []
    if input.magic != tsOmit {
        let mg: UInt32 = input.magic == tsKeep ? magicTombstone : UInt32(truncatingIfNeeded: input.magic)
        buf.append(UInt8(truncatingIfNeeded: mg >> 24))
        buf.append(UInt8(truncatingIfNeeded: mg >> 16))
        buf.append(UInt8(truncatingIfNeeded: mg >> 8))
        buf.append(UInt8(truncatingIfNeeded: mg))
    }
    if Int64(input.version) != tsOmit {
        buf.append(
            Int64(input.version) == tsKeep
                ? tombstoneFormatV1 : UInt8(truncatingIfNeeded: input.version))
    }
    buf.append(contentsOf: body)
    if input.crc != tsOmit {
        let c: UInt32 =
            input.crc == tsKeep ? CRC32C.checksum(body) : UInt32(truncatingIfNeeded: input.crc)
        buf.append(UInt8(truncatingIfNeeded: c >> 24))
        buf.append(UInt8(truncatingIfNeeded: c >> 16))
        buf.append(UInt8(truncatingIfNeeded: c >> 8))
        buf.append(UInt8(truncatingIfNeeded: c))
    }
    buf.append(contentsOf: trailer)

    if input.truncateTo >= 0 && input.truncateTo < buf.count {
        buf = Array(buf[0..<input.truncateTo])
    }
    return buf
}

/// The oracle's `tsDecodeInput`: the version byte, if present, then the body. Independent of the truncation,
/// which is a property of the FILE rather than of the payload.
func tsDecodeInput(_ input: TSCorruptIn) -> [UInt8] {
    var buf: [UInt8] = []
    if Int64(input.version) != tsOmit {
        buf.append(
            Int64(input.version) == tsKeep
                ? tombstoneFormatV1 : UInt8(truncatingIfNeeded: input.version))
    }
    buf.append(contentsOf: Hex.decode(input.body ?? ""))
    return buf
}

/// Sort a thrown error into the fixture's `err` or `panic` field. Upstream's is a real `runtime.Error` that
/// `recover` catches; the port's is a thrown `TombstoneFileError` carrying the same text, because the panic
/// is REACHABLE and a Swift trap would not be catchable (HANDOFF §5, `extendFloats`).
private func tsSplitError(_ error: any Error, _ err: inout String, _ panic: inout String) {
    let text = "\(error)"
    if text.hasPrefix("runtime error: ") {
        panic = text
    } else {
        err = text
    }
}

// MARK: - The suite

@Suite("tombstones: the reader against corrupt and truncated bytes")
struct TombstoneCorruptTests {

    @Test("every committed corruption case matches Go")
    func matchesGo() throws {
        try Fixtures.check("tombstones/corrupt.jsonl", FixtureCase<TSCorruptIn, TSCorruptOut>.self) {
            input in
            let fs = InMemoryFS()
            let dir = "block"
            try fs.createDirectory(dir)

            var out = TSCorruptOut(
                file: "", err: "", panic: "", size: 0, total: 0, entries: [], decodeErr: "",
                decodePanic: "", decodeTotal: 0, decodeEntries: [])

            if !input.absent {
                let bytes = tsAssemble(input)
                out.file = Hex.encode(bytes)
                let h = try fs.createFile("\(dir)/\(tombstonesFilename)")
                try h.append(bytes)
                try h.close()
            }

            do {
                let (tr, size) = try readTombstones(fs, dir)
                out.size = size
                out.total = tr.total()
                out.entries = tsFlatten(tr)
            } catch {
                tsSplitError(error, &out.err, &out.panic)
            }

            do {
                let tr = try decodeTombstones(tsDecodeInput(input))
                out.decodeTotal = tr.total()
                out.decodeEntries = tsFlatten(tr)
            } catch {
                tsSplitError(error, &out.decodeErr, &out.decodePanic)
            }

            return out
        }
    }

    // MARK: - The rejection paths, spelled out

    /// The four error strings, asserted as strings rather than through a fixture comparison, so a change to
    /// one of them is a failure that *names itself*. `%x` in Go is lowercase and unpadded — the corpus has
    /// `invalid magic number 130ba` for `0x000130BA`, which is what says the port must not zero-pad.
    @Test("the contract strings")
    func contractStrings() {
        #expect("\(TombstoneFileError.header(.invalidSize))" == "tombstones header: invalid size")
        #expect("\(TombstoneFileError.invalidMagicNumber(0))" == "invalid magic number 0")
        #expect(
            "\(TombstoneFileError.invalidMagicNumber(0x0001_30BA))" == "invalid magic number 130ba")
        #expect(
            "\(TombstoneFileError.invalidMagicNumber(0xFFFF_FFFF))"
                == "invalid magic number ffffffff")
        #expect("\(TombstoneFileError.checksumDidNotMatch)" == "checksum did not match")
        #expect("\(TombstoneFileError.invalidTombstoneFormat(0))" == "invalid tombstone format 0")
        #expect("\(TombstoneFileError.invalidTombstoneFormat(0xFF))" == "invalid tombstone format ff")
        #expect("\(TombstoneFileError.decode(.invalidSize))" == "invalid size")
        #expect(
            "\(TombstoneFileError.encodingTombstones("boom"))" == "encoding tombstones: boom")
        #expect("\(TombstoneFileError.writingTombstones("boom"))" == "writing tombstones: boom")
        #expect(
            "\(TombstoneFileError.sliceBoundsOutOfRange(low: 1, high: 0))"
                == "runtime error: slice bounds out of range [1:0]")
    }

    /// **Quirk 210.** The panic is the one behaviour a reader of the port must not "fix": upstream really
    /// does take the process down on an eight-byte tombstone file, and a port that answered a tidy error
    /// would diverge on a path `OpenBlock` reaches. The corpus pins it; this names it.
    @Test("an eight-byte file is upstream's panic, not an error")
    func eightByteFilePanics() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("block")
        let h = try fs.createFile("block/tombstones")
        try h.append(Hex.decode("0130ba3000000000"))
        try h.close()
        #expect(throws: TombstoneFileError.sliceBoundsOutOfRange(low: 1, high: 0)) {
            _ = try readTombstones(fs, "block")
        }
    }

    /// **Quirk 211.** The checksum's input starts *after* the version byte, at both ends. So the byte that
    /// decides whether the file can be parsed at all is the one byte the checksum does not protect.
    @Test("the checksum does not cover the version byte")
    func checksumExcludesVersion() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("block")
        // A valid one-entry file, with the version byte changed and the CRC left alone.
        var bytes = Hex.decode("0130ba300107020a5833dfc5")
        bytes[4] = 2
        let h = try fs.createFile("block/tombstones")
        try h.append(bytes)
        try h.close()
        // Not `checksum did not match` — the checksum passes and `Decode` is what rejects it.
        #expect(throws: TombstoneFileError.invalidTombstoneFormat(2)) {
            _ = try readTombstones(fs, "block")
        }
    }

    /// **Quirk 213.** Both `if d.Err() != nil` checks are dead: every read that could latch an error has a
    /// more specific arm above it. Asserted through `Decode` on an EMPTY buffer, which is the one place the
    /// substitution is visible — `Byte()` latches `invalid size` and returns 0, and 0 is answered as a
    /// FORMAT error.
    @Test("an empty buffer is a format error, not a size error")
    func emptyBufferIsAFormatError() {
        #expect(throws: TombstoneFileError.invalidTombstoneFormat(0)) {
            _ = try decodeTombstones([])
        }
    }
}
