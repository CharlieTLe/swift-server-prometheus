//===----------------------------------------------------------------------===//
// The XOR2 encoding, byte for byte — **and with it `varbit.go`**, whose five functions are unexported
// upstream and whose only route to a corpus is a chunk that uses them. §6c said the pinning would
// arrive here; this is it.
//
// Same seam as `chunkenc/xor.jsonl`, plus `AtST()` per sample, which is the whole reason XOR2 exists.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromChunkEnc
import Testing

struct XOR2Sample: Codable, Equatable, Sendable {
    var st: Int64
    var t: Int64
    var v: String
}

struct XOR2In: Codable, Sendable {
    var samples: [XOR2Sample]?
    var splitAt: Int
    var readFirst: Int
}

struct XOR2Out: Decodable, Equatable, Sendable {
    var bytes: String
    var numSamples: Int
    var stHeader: UInt8
    var read: [XOR2Sample]
    var replayBytes: String
    var err: String
}

private func b2(_ s: String) -> Double { Double(bitPattern: UInt64(s, radix: 16)!) }
private func h2(_ d: Double) -> String { String(format: "%016lx", d.bitPattern) }
private func h2(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

@Suite("chunkenc: XOR2 encoding, start timestamps, and varbit under it")
struct XOR2ChunkTests {

    @Test("every committed case matches Go, byte for byte")
    func matchesGo() throws {
        try Fixtures.check("chunkenc/xor2.jsonl", FixtureCase<XOR2In, XOR2Out>.self) { input in
            let samples = input.samples ?? []
            var out = XOR2Out(
                bytes: "", numSamples: 0, stHeader: 0, read: [], replayBytes: "", err: "")

            let c = XOR2Chunk()
            let app = try c.appender()
            let split = input.splitAt == 0 ? samples.count : input.splitAt
            for s in samples[0..<split] {
                app.append(s.st, s.t, b2(s.v))
            }
            var it = c.iterator()
            for _ in 0..<input.readFirst {
                if it.next() != .float { break }
                let (t, v) = it.at
                out.read.append(XOR2Sample(st: it.atST, t: t, v: h2(v)))
            }
            for s in samples[split...] {
                app.append(s.st, s.t, b2(s.v))
            }
            while it.next() == .float {
                let (t, v) = it.at
                out.read.append(XOR2Sample(st: it.atST, t: t, v: h2(v)))
            }
            if let err = it.err {
                out.err = String(describing: err)
            }
            out.bytes = h2(c.bytes)
            out.numSamples = c.numSamples
            if c.bytes.count > 2 {
                out.stHeader = c.bytes[2]
            }

            // The replay: XOR2 recovers more state than XOR — the ST bookkeeping, the write bit
            // position, and `baselineV` rather than `val` — so this check earns more here.
            if !samples.isEmpty && input.splitAt == 0 {
                let c3 = XOR2Chunk()
                c3.reset(c.bytes)
                let app3 = try c3.appender()
                let last = samples[samples.count - 1]
                let st = last.st != 0 ? last.st + 500 : 0
                app3.append(st, last.t + 1000, b2(last.v) + 1)
                out.replayBytes = h2(c3.bytes)
            }
            return out
        }
    }
}
