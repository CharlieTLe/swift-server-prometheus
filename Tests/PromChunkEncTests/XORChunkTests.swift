//===----------------------------------------------------------------------===//
// The XOR chunk encoding, byte for byte — **and with it `Bstream.swift`, which had no corpus of its
// own.** `bstream` is unexported upstream so the oracle cannot call it; the chunk's bytes ARE the bit
// stream it wrote, so comparing them checks every write, and iterating them back checks every read.
// HANDOFF §5d said the two files were one unit of verification.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromChunkEnc
import Testing

struct XORSample: Codable, Equatable, Sendable {
    var t: Int64
    /// A hex bit pattern, so NaN, the stale NaN and `-0` travel exactly.
    var v: String
}

struct XORIn: Codable, Sendable {
    var samples: [XORSample]?
    /// See the oracle suite: append `splitAt`, make an iterator, read `readFirst`, append the rest,
    /// keep reading. `0`/`0` is the plain case.
    var splitAt: Int
    var readFirst: Int
}

struct XOROut: Decodable, Equatable, Sendable {
    var bytes: String
    var numSamples: Int
    var read: [XORSample]
    var replayT: Int64
    var replayV: String
    var replayTDelta: UInt64
    var replayLeading: UInt8
    var replayTrailing: UInt8
    var err: String
}

private func bits(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
private func hexOf(_ d: Double) -> String { String(format: "%016lx", d.bitPattern) }
private func hexOf(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
private func unhexBytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

/// Append part of the series, make an iterator, read some, then append the rest and keep reading
/// through the SAME iterator.
///
/// This is what pins `newBReader`'s copy of the final byte and `loadNextBuffer`'s `+8 <` boundary. Both
/// are framed upstream as a concurrency accommodation, and both controls survived the first corpus —
/// but no threads are needed to see them: the point is simply that the last byte changed after the
/// reader took its copy, and the reader is defined to keep reading the copy.
private func runSplitCase(_ samples: [XORSample], _ splitAt: Int, _ readFirst: Int) throws -> XOROut {
    let c = XORChunk()
    let app = try c.appender()
    for s in samples[0..<splitAt] {
        app.append(s.t, bits(s.v))
    }
    var out = XOROut(
        bytes: "", numSamples: 0, read: [], replayT: 0, replayV: "", replayTDelta: 0,
        replayLeading: 0, replayTrailing: 0, err: "")
    // Created HERE, over the chunk as it stands.
    var it = c.iterator()
    for _ in 0..<readFirst {
        if it.next() != .float { break }
        let (t, v) = it.at
        out.read.append(XORSample(t: t, v: hexOf(v)))
    }
    for s in samples[splitAt...] {
        app.append(s.t, bits(s.v))
    }
    while it.next() == .float {
        let (t, v) = it.at
        out.read.append(XORSample(t: t, v: hexOf(v)))
    }
    if let err = it.err {
        out.err = String(describing: err)
    }
    out.bytes = hexOf(c.bytes)
    out.numSamples = c.numSamples
    return out
}

@Suite("chunkenc: XOR encoding, and the bit stream under it")
struct XORChunkTests {

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("chunkenc/xor.jsonl", FixtureCase<XORIn, XOROut>.self) { input in
            let samples = input.samples ?? []
            if input.splitAt > 0 {
                return try runSplitCase(samples, input.splitAt, input.readFirst)
            }
            let c = XORChunk()
            let app = try c.appender()
            for s in samples {
                app.append(s.t, bits(s.v))
            }
            var out = XOROut(
                bytes: hexOf(c.bytes), numSamples: c.numSamples, read: [], replayT: 0, replayV: "",
                replayTDelta: 0, replayLeading: 0, replayTrailing: 0, err: "")

            var it = c.iterator()
            while it.next() == .float {
                let (t, v) = it.at
                out.read.append(XORSample(t: t, v: hexOf(v)))
            }
            if let err = it.err {
                out.err = String(describing: err)
            }

            // The REPLAY check: a fresh chunk over the same bytes, then one more sample. If
            // `appender()`'s replay recovered the wrong encoder state — the last timestamp, value,
            // delta, or the leading/trailing window — these bytes differ. That is the only way those
            // fields are observable, since they are unexported upstream.
            if !samples.isEmpty {
                let c3 = XORChunk()
                c3.reset(c.bytes)
                let app3 = try c3.appender()
                let last = samples[samples.count - 1]
                app3.append(last.t + 1000, bits(last.v) + 1)
                out.replayV = hexOf(c3.bytes)
                out.replayT = Int64(c3.numSamples)
            }
            return out
        }
    }
}
