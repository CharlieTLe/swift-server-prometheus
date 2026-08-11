//===----------------------------------------------------------------------===//
// `index.Writer`'s meta, symbol and series stages, compared against Go's real index files.
//
// **The comparison is the WHOLE FILE**, byte for byte, plus every TOC offset — the magic and version, the
// symbol table with its back-patched length, count and hash, every series record, the postings lists, and
// the postings offset table with its adjusted offsets.
//
// `index/reader.jsonl` supplies Go's files, so this suite needs no corpus of its own and the two cannot
// drift apart. Comparing bytes rather than round-tripping matters: a writer bug and a reader bug that
// cancelled out would pass a round-trip test and fail this one.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromEncoding
import PromFS
import PromIndex
import Testing

@Suite("index: the writer's meta, symbol and series stages")
struct IndexWriterTests {

    /// Rebuilds each corpus file's input with the port's writer and compares the ENTIRE file against Go's,
    /// byte for byte, plus every TOC offset.
    ///
    /// §6i started as a prefix comparison because the postings sections were not ported; they are now, so
    /// this is the whole file. The reader suite's fixtures supply Go's files, which means a writer bug and a
    /// reader bug cannot cancel out — the bytes are compared directly rather than round-tripped.
    @Test("the written file is byte-identical to Go's")
    func fileMatchesGo() throws {
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

            // **The WHOLE file now**, not a prefix: the postings sections landed, so the port writes
            // every section Go does and the two files should be identical byte for byte.
            if goBytes != portBytes {
                let firstDiff = zip(goBytes, portBytes).enumerated().first {
                    $0.element.0 != $0.element.1
                }?.offset ?? min(goBytes.count, portBytes.count)
                mismatches.append(
                    "\(decoded.id): differs at byte \(firstDiff) (go \(goBytes.count) bytes, "
                        + "port \(portBytes.count))")
            }
            // Every TOC offset, not just the two the prefix covered.
            let portTOC = w.toc
            if portTOC != IndexTOC(
                symbols: expected.toc.symbols, series: expected.toc.series,
                labelIndices: expected.toc.labelIndices,
                labelIndicesTable: expected.toc.labelIndicesTable,
                postings: expected.toc.postings, postingsTable: expected.toc.postingsTable)
            {
                mismatches.append(
                    "\(decoded.id): toc \(portTOC) want symbols=\(expected.toc.symbols) "
                        + "series=\(expected.toc.series) li=\(expected.toc.labelIndices) "
                        + "lit=\(expected.toc.labelIndicesTable) p=\(expected.toc.postings) "
                        + "pt=\(expected.toc.postingsTable)")
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
