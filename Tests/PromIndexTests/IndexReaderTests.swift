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
                lookedUp: [], lookupErrs: [], reversed: [], reverseErrs: [])

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
