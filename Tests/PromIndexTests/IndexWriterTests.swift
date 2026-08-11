//===----------------------------------------------------------------------===//
// `index.Writer`'s meta, symbol and series stages, compared against Go's real index files.
//
// **The comparison is a PREFIX comparison, and that is a deliberate limit rather than a shortcut.** The
// port does not write the postings sections yet (§6i owns them), so its TOC offsets diverge from Go's after
// the series section — but everything up to `toc.Series`'s end is written by the code under test and is
// byte-identical, so that range is what is compared. `index/reader.jsonl` supplies Go's files; this reuses
// them rather than needing a corpus of its own, which also means the two suites cannot drift apart.
//
// What the prefix covers: the magic and version, the symbol table with its back-patched length, count and
// hash, and every series record with its padding, uvarint length prefix, label ordinals, double-delta chunk
// metas and hash. That is the whole of what this slice writes.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromEncoding
import PromFS
import PromIndex
import Testing

@Suite("index: the writer's meta, symbol and series stages")
struct IndexWriterTests {

    /// Rebuilds each corpus file's input with the port's writer and compares the byte range Go's own TOC
    /// says belongs to the symbol and series sections.
    @Test("the written prefix is byte-identical to Go's")
    func prefixMatchesGo() throws {
        var checked = 0
        var mismatches: [String] = []

        // `Fixtures.load` decodes the whole file with one type, which is what this needs — the reader
        // suite's own `In`/`Out` pair, reused so the two suites cannot drift apart.
        for decoded in try Fixtures.load("index/reader.jsonl", FixtureCase<IndexReaderIn, IndexReaderOut>.self) {
            let input = decoded.in
            let expected = decoded.out
            // Cases where Go's writer failed have no file to compare against.
            guard !input.fileHex.isEmpty, expected.tocErr.isEmpty else { continue }

            let goBytes = unhexW(input.fileHex)
            // The symbols the oracle added: the case's values plus the label name "l", de-duplicated and
            // sorted with Go's ordering — exactly what the generator does.
            //
            // **De-duplicated by BYTES, not by `String` equality.** Swift compares strings by Unicode
            // canonical equivalence, so `"e\u{301}" == "é"` is TRUE in Swift and FALSE in Go — and one
            // corpus case contains both spellings, which Go writes as two distinct symbols. A
            // `Set<String>` collapsed them into one, the port wrote six symbols where Go wrote seven, and
            // the prefix diverged four bytes in. ADR-10 is about ordering; this is the same hazard in
            // equality, and it bit the harness rather than the port.
            var seen = Set<[UInt8]>()
            var syms: [String] = []
            for s in (input.symbols ?? []) + ["l"] where seen.insert(Array(s.utf8)).inserted {
                syms.append(s)
            }
            let sorted = syms.sorted { goStringLessW($0, $1) }
            // Byte comparison again, for the same reason.
            let seriesVals = sorted.filter { Array($0.utf8) != Array("l".utf8) }

            let fs = InMemoryFS()
            let w = try IndexWriter(fs: fs, path: "idx")
            for s in sorted {
                try w.addSymbol(s)
            }
            for (i, v) in seriesVals.enumerated() {
                let metas = (input.chunkMetas ?? []).map {
                    (minTime: $0[0], maxTime: $0[1], ref: UInt64($0[2] + Int64(i) * 1_000_000))
                }
                try w.addSeries(
                    ref: UInt64(i + 1), labels: [(name: "l", value: v)], chunks: metas)
            }
            try w.close()

            let r = try fs.openForReading("idx")
            let portBytes = try r.read(offset: 0, length: r.size)
            try r.close()

            // Go's TOC says where the series section ends: the next section's offset. With no postings
            // written by the port, Go's `labelIndices` is the first offset past the series records.
            let prefixEnd = Int(expected.toc.labelIndices)
            guard prefixEnd > 0, prefixEnd <= goBytes.count, prefixEnd <= portBytes.count else {
                mismatches.append(
                    "\(decoded.id): prefix end \(prefixEnd) out of range "
                        + "(go \(goBytes.count), port \(portBytes.count))")
                continue
            }
            let goPrefix = Array(goBytes[0..<prefixEnd])
            let portPrefix = Array(portBytes[0..<prefixEnd])
            if goPrefix != portPrefix {
                // Report the first differing offset, which localises a framing bug immediately.
                let firstDiff = zip(goPrefix, portPrefix).enumerated().first { $0.element.0 != $0.element.1 }?
                    .offset ?? min(goPrefix.count, portPrefix.count)
                mismatches.append(
                    "\(decoded.id): prefix differs at byte \(firstDiff) of \(prefixEnd)")
            }
            // And the TOC offsets the port computed for the sections it wrote must agree.
            if w.toc.symbols != expected.toc.symbols || w.toc.series != expected.toc.series {
                mismatches.append(
                    "\(decoded.id): toc symbols/series \(w.toc.symbols)/\(w.toc.series) "
                        + "want \(expected.toc.symbols)/\(expected.toc.series)")
            }
            checked += 1
        }

        #expect(checked > 0, "no comparable cases found — the corpus shape changed")
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20).joined(separator: "\n"))")
    }
}

private func unhexW(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

private func goStringLessW(_ a: String, _ b: String) -> Bool {
    Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
}
