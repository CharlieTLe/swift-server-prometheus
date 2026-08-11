//===----------------------------------------------------------------------===//
// The index file's header, table of contents and symbol table.
//
// **The corpus contains real index files.** The oracle writes each one with Go's own `index.Writer` and
// emits its bytes as hex; the port parses them. So the reader is pinned against upstream's serialiser
// without the port needing a writer — which matters because `index.Writer` is file-based and ADR-15
// defers that.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromEncoding
import PromIndex
import Testing

struct IndexReaderIn: Codable, Sendable {
    /// Optional because Go marshals a **nil slice as `null`**, not `[]` — the same trap the convertnhcb
    /// corpus hit. A case that performs no lookups has `"lookups": null`.
    var symbols: [String]?
    var lookups: [UInt32]?
    var reverse: [String]?
    var truncateTo: Int
    var corruptTOCCRC: Bool
    var seriesIDs: [UInt64]?
    var chunkMetas: [[Int64]]?
    var postingsQueries: [[String]]?
    var labelValueQueries: [[String]]?
    var labelNamesForIDs: [[UInt64]]?
    /// `(name, predicate-spec)` pairs. A closure cannot cross JSONL, so the fixture names a predicate
    /// both sides build — see `matchPredicate`. The spec `nil` means `PostingsForAllLabelValues`, which is
    /// a DIFFERENT branch upstream from a predicate that always returns true.
    var matchQueries: [[String]]?
    /// The generated file's bytes. INPUT, because the port has no index writer — the oracle writes the
    /// file with Go's own `index.Writer` and hands the bytes over. On the output side this would be the
    /// port comparing against itself.
    var fileHex: String
}

struct TOCFields: Codable, Equatable, Sendable {
    var symbols: UInt64
    var series: UInt64
    var labelIndices: UInt64
    var labelIndicesTable: UInt64
    var postings: UInt64
    var postingsTable: UInt64
}

struct IndexReaderOut: Decodable, Equatable, Sendable {
    var toc: TOCFields
    var tocErr: String
    var symbolCount: Int
    var symbolSize: Int
    var allSymbols: [String]
    var symbolsErr: String
    var lookedUp: [String]
    var lookupErrs: [String]
    var reversed: [UInt32]
    var reverseErrs: [String]
    var seriesLabels: [[String]]
    var seriesChunks: [[[Int64]]]
    var seriesErrs: [String]
    var tableNames: [String]
    var tableValues: [String]
    var tableOffs: [UInt64]
    var tableEntryAt: [Int]
    var tableErr: String
    var queryResults: [[UInt64]]
    var queryErrs: [String]
    var labelNames: [String]
    var labelNamesErr: String
    var labelValues: [[String]]
    var labelValuesErrs: [String]
    var namesFor: [[String]]
    var namesForErrs: [String]
    var matchResults: [[UInt64]]
    var matchErrs: [String]
}

/// The `matchQueries` vocabulary, built to match `oracle/suites_index_reader.go`'s `matchPredicate`
/// name for name. Both degenerate cases are here on purpose: `all` and `none` are what decide whether
/// the traversal's `val != lastVal` stop condition and the empty-postings return are reached.
private func matchPredicate(_ spec: String) -> (String) -> Bool {
    if spec == "all" { return { _ in true } }
    if spec == "none" { return { _ in false } }
    if spec == "empty" { return { $0.isEmpty } }
    if spec.hasPrefix("eq:") {
        let want = String(spec.dropFirst(3))
        return { $0 == want }
    }
    if spec.hasPrefix("ne:") {
        let unwanted = String(spec.dropFirst(3))
        return { $0 != unwanted }
    }
    if spec.hasPrefix("prefix:") {
        let p = String(spec.dropFirst(7))
        return { $0.hasPrefix(p) }
    }
    if spec.hasPrefix("suffix:") {
        let p = String(spec.dropFirst(7))
        return { $0.hasSuffix(p) }
    }
    if spec.hasPrefix("contains:") {
        let p = String(spec.dropFirst(9))
        return { $0.contains(p) }
    }
    if spec.hasPrefix("longerthan:") {
        let want = Int(spec.dropFirst("longerthan:".count)) ?? 0
        // Go's `len(v)` is a BYTE count, not a character count (ADR-9's neighbour), so `é` is 2.
        return { $0.utf8.count > want }
    }
    fatalError("unknown match predicate spec: \(spec)")
}

private func unhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

@Suite("index: the file header, TOC and symbol table")
struct IndexReaderTests {

    @Test("every committed index file parses exactly as Go parses it")
    func matchesGo() throws {
        try Fixtures.check("index/reader.jsonl", FixtureCase<IndexReaderIn, IndexReaderOut>.self) {
            input in
            var out = IndexReaderOut(
                toc: TOCFields(
                    symbols: 0, series: 0, labelIndices: 0, labelIndicesTable: 0, postings: 0,
                    postingsTable: 0),
                tocErr: "", symbolCount: 0, symbolSize: 0, allSymbols: [], symbolsErr: "",
                lookedUp: [], lookupErrs: [], reversed: [], reverseErrs: [], seriesLabels: [],
                seriesChunks: [], seriesErrs: [], tableNames: [], tableValues: [], tableOffs: [],
                tableEntryAt: [], tableErr: "", queryResults: [], queryErrs: [], labelNames: [],
                labelNamesErr: "", labelValues: [], labelValuesErrs: [], namesFor: [],
                namesForErrs: [], matchResults: [], matchErrs: [])

            // The oracle already wrote the file and handed it over, so the port never writes one — which
            // is the whole point of this seam.
            let raw = unhex(input.fileHex)
            if raw.isEmpty {
                // The oracle failed before producing a file; nothing to compare but the error, and the
                // fixture carries it.
                return out
            }
            return try raw.withUnsafeBytes { rawBuf -> IndexReaderOut in
                let bs = ByteSlice(rawBuf)
                let toc: IndexTOC
                do {
                    toc = try IndexTOC(byteSlice: bs)
                } catch {
                    out.tocErr = String(describing: error)
                    return out
                }
                out.toc = TOCFields(
                    symbols: toc.symbols, series: toc.series, labelIndices: toc.labelIndices,
                    labelIndicesTable: toc.labelIndicesTable, postings: toc.postings,
                    postingsTable: toc.postingsTable)

                let sy: IndexSymbols
                do {
                    sy = try IndexSymbols(
                        byteSlice: bs, version: indexFormatV2, off: Int(toc.symbols))
                } catch {
                    out.symbolsErr = String(describing: error)
                    return out
                }
                out.symbolSize = sy.size
                do {
                    let all = try sy.all()
                    out.allSymbols = all
                    out.symbolCount = all.count
                } catch {
                    out.symbolsErr = String(describing: error)
                }

                for o in input.lookups ?? [] {
                    do {
                        out.lookedUp.append(try sy.lookup(o))
                        out.lookupErrs.append("")
                    } catch {
                        // Go returns `("", err)`, so an empty string accompanies every error.
                        out.lookedUp.append("")
                        out.lookupErrs.append(String(describing: error))
                    }
                }
                // The series records. `readSeries` resolves the ID through the v2 byte alignment and the
                // symbol table, then decodes the chunk metas' double-delta encoding.
                for id in input.seriesIDs ?? [] {
                    do {
                        let series = try readSeries(
                            bs, id: id, version: indexFormatV2,
                            lookupSymbol: { try sy.lookup($0) })
                        var pairs: [String] = []
                        for l in series.labels {
                            pairs.append(l.name)
                            pairs.append(l.value)
                        }
                        out.seriesLabels.append(pairs)
                        out.seriesChunks.append(
                            series.chunks.map { [$0.minTime, $0.maxTime, Int64(bitPattern: $0.ref)] })
                        out.seriesErrs.append("")
                    } catch {
                        out.seriesLabels.append([])
                        out.seriesChunks.append([])
                        out.seriesErrs.append(String(describing: error))
                    }
                }
                // The postings offset table, every entry.
                do {
                    try readPostingsOffsetTable(bs, off: toc.postingsTable) {
                        name, value, o, entryAt in
                        out.tableNames.append(name)
                        out.tableValues.append(value)
                        out.tableOffs.append(o)
                        out.tableEntryAt.append(entryAt)
                    }
                } catch {
                    out.tableErr = String(describing: error)
                }

                // `Postings(name, values...)`, which exercises the sparse index, the traversal with its
                // name-width skip, and the raw postings decoder together.
                if let queries = input.postingsQueries, !queries.isEmpty {
                    let sparse = (try? buildPostingsOffsetIndex(bs, postingsTable: toc.postingsTable))
                        ?? [:]
                    for q in queries where !q.isEmpty {
                        do {
                            let lists = try indexPostings(
                                bs, postingsTable: toc.postingsTable, sparse: sparse, name: q[0],
                                values: Array(q.dropFirst()))
                            let refs = try expandPostings(merge(lists))
                            out.queryResults.append(refs.map(\.rawValue))
                            out.queryErrs.append("")
                        } catch {
                            out.queryResults.append([])
                            out.queryErrs.append(String(describing: error))
                        }
                    }
                }

                // LabelNames over the whole file, then LabelValues and LabelNamesFor per query.
                let sparseAll =
                    (try? buildPostingsOffsetIndex(bs, postingsTable: toc.postingsTable)) ?? [:]
                out.labelNames = indexLabelNames(sparseAll)
                for q in input.labelValueQueries ?? [] {
                    let limit = q.count > 1 ? (Int(q[1]) ?? 0) : 0
                    do {
                        out.labelValues.append(
                            try indexLabelValues(
                                bs, postingsTable: toc.postingsTable, sparse: sparseAll,
                                name: q[0], limit: limit))
                        out.labelValuesErrs.append("")
                    } catch {
                        out.labelValues.append([])
                        out.labelValuesErrs.append(String(describing: error))
                    }
                }
                for ids in input.labelNamesForIDs ?? [] {
                    do {
                        out.namesFor.append(
                            try indexLabelNamesFor(
                                bs, version: indexFormatV2, seriesIDs: ids,
                                lookupSymbol: { try sy.lookup($0) }))
                        out.namesForErrs.append("")
                    } catch {
                        out.namesFor.append([])
                        out.namesForErrs.append(String(describing: error))
                    }
                }

                for q in input.matchQueries ?? [] where q.count == 2 {
                    do {
                        // `nil` must take the OTHER branch, not pass an always-true closure.
                        let p = try indexPostingsForLabelMatching(
                            bs, postingsTable: toc.postingsTable, sparse: sparseAll, name: q[0],
                            match: q[1] == "nil" ? nil : matchPredicate(q[1]))
                        out.matchResults.append(try expandPostings(p).map(\.rawValue))
                        out.matchErrs.append("")
                    } catch {
                        out.matchResults.append([])
                        out.matchErrs.append(String(describing: error))
                    }
                }

                for s in input.reverse ?? [] {
                    do {
                        out.reversed.append(try sy.reverseLookup(s))
                        out.reverseErrs.append("")
                    } catch {
                        out.reversed.append(0)
                        out.reverseErrs.append(String(describing: error))
                    }
                }
                return out
            }
        }
    }
}
