// swift-tools-version:6.1
//===----------------------------------------------------------------------===//
//
// Prometheus, ported from Go to Swift.
//
// Upstream reference: github.com/prometheus/prometheus @ v3.13.2 (bb5dff00c)
// See docs/PORTING.md for the fidelity contract and docs/ROADMAP.md for phases.
//
//===----------------------------------------------------------------------===//

import PackageDescription

// Phase 1 is deliberately dependency-free: xxhash64, CRC32-C, varint and Go float
// formatting are all hand-rolled (see docs/DECISIONS.md). SSWG dependencies
// (NIO, Hummingbird, ServiceLifecycle, Yams, swift-protobuf, ...) arrive with the
// phases that need them.
let package = Package(
    name: "prometheus",
    platforms: [.macOS(.v15)],
    products: [
        // Phase 1 foundations. These are the byte-exactness substrate; everything
        // downstream depends on them being correct.
        .library(name: "GoCompat", targets: ["GoCompat"]),
        .library(name: "PromHash", targets: ["PromHash"]),
        .library(name: "PromMath", targets: ["PromMath"]),
        .library(name: "PromModel", targets: ["PromModel"]),
        .library(name: "PromRegex", targets: ["PromRegex"]),
        .library(name: "PromHistogram", targets: ["PromHistogram"]),
        .library(name: "PromPosRange", targets: ["PromPosRange"]),
        .library(name: "PromAnnotations", targets: ["PromAnnotations"]),
        .library(name: "PromChunkEnc", targets: ["PromChunkEnc"]),
        .library(name: "PromIndex", targets: ["PromIndex"]),
        .library(name: "PromFS", targets: ["PromFS"]),
        .library(name: "PromBlock", targets: ["PromBlock"]),
        .library(name: "PromTombstones", targets: ["PromTombstones"]),
        .library(name: "PromRecord", targets: ["PromRecord"]),
        .library(name: "PromWAL", targets: ["PromWAL"]),
        .library(name: "PromHead", targets: ["PromHead"]),
        .library(name: "PromChunks", targets: ["PromChunks"]),
        .library(name: "PromStorage", targets: ["PromStorage"]),
        .library(name: "PromTestStorage", targets: ["PromTestStorage"]),
        .library(name: "PromQLParser", targets: ["PromQLParser"]),
        .library(name: "PromQL", targets: ["PromQL"]),
        .library(name: "PromQLTest", targets: ["PromQLTest"]),
        .library(name: "PromConvertNHCB", targets: ["PromConvertNHCB"]),
        .library(name: "PromLabels", targets: ["PromLabels"]),
        .library(name: "PromSchema", targets: ["PromSchema"]),
        .library(name: "PromEncoding", targets: ["PromEncoding"]),
        // The fuzz differ: generates candidate inputs and diffs Swift against the Go oracle.
        .executable(name: "promdiff", targets: ["promdiff"]),
    ],
    targets: [
        // ── Tier 0 ───────────────────────────────────────────────────────────
        .target(name: "GoCompat"),
        .target(name: "PromHash"),

        // ── Tier 1 ───────────────────────────────────────────────────────────
        .target(name: "PromModel", dependencies: ["GoCompat"]),
        // Mirrors Go: util/almost imports model/value.
        .target(name: "PromMath", dependencies: ["PromModel"]),
        // Phase 2: a real RE2 in Swift. See docs/DECISIONS.md ADR-6.
        .target(name: "PromRegex", dependencies: ["GoCompat"]),
        // Phase 3: native histograms. See docs/DECISIONS.md ADR-7.
        // The PromLabels edge is convert.go's: upstream's model/histogram imports
        // model/labels to emit classic series from an NHCB.
        .target(
            name: "PromHistogram",
            dependencies: ["PromModel", "PromMath", "PromLabels", "GoCompat"]
        ),
        .target(
            name: "PromLabels",
            dependencies: ["PromModel", "PromHash", "PromRegex", "GoCompat"]
        ),

        // ── Tier 2 ───────────────────────────────────────────────────────────
        .target(name: "PromEncoding", dependencies: ["PromHash", "GoCompat"]),

        // `prometheus/schema`, which sits directly above `model/labels` and below
        // both `promql` and (Phase 8) `model/textparse`. Its own target because
        // upstream keeps it its own package and because every target here maps
        // one-to-one onto a Go package.
        .target(name: "PromSchema", dependencies: ["PromLabels", "PromModel"]),

        // Phase 5. The tier order below is Go's own, and the split of
        // `PromPosRange` out of `PromQLParser` is forced rather than stylistic:
        //
        //   promql/parser -> storage -> util/annotations -> promql/parser/posrange
        //
        // Upstream keeps `posrange` a separate package precisely to break that
        // cycle. Folding it back into `PromQLParser` makes the graph circular.
        .target(name: "PromPosRange"),
        .target(name: "PromAnnotations", dependencies: ["PromPosRange", "PromModel", "GoCompat"]),
        // Phase 5 ports only chunk.go's protocol surface; the concrete XOR,
        // XOR2 and histogram encodings arrive with Phases 6–7.
        .target(name: "PromChunkEnc", dependencies: ["PromHistogram", "PromModel", "GoCompat"]),
        .target(
            name: "PromChunks",
            // Phase 6 added `ChunkFormat.swift`, which needs the Castagnoli CRC and varints.
            dependencies: ["PromChunkEnc", "PromHistogram", "PromHash", "PromFS", "GoCompat"]
        ),

        // Phase 6: the filesystem seam ADR-15 decided. NOT a port — it stands in for the parts of `os`,
        // `fileutil` and `mmap` the TSDB reaches for, with an in-memory implementation so corpora need no
        // scratch directory.
        .target(name: "PromFS", dependencies: ["PromEncoding"]),

        // Phase 6: `tsdb/tombstones`' interval arithmetic, plus Phase 7's `Stone`. Its own target
        // because it is Go's own package boundary and because `tsdb/record` imports it without
        // importing anything else of the block.
        .target(name: "PromTombstones", dependencies: ["PromStorage", "GoCompat"]),

        // Phase 7: `tsdb/wlog` — the segment framing the records travel in.
        .target(name: "PromWAL", dependencies: ["PromFS", "PromHash", "GoCompat"]),

        // Phase 7: the Head. `tsdb/isolation.go` first, because `defaultIsolationDisabled` is false — every
        // `NewHead` runs it, and every append takes an ID from it. See HANDOFF §7f.
        .target(
            name: "PromHead",
            dependencies: [
                "PromBlock", "PromChunkEnc", "PromChunks", "PromFS", "PromHistogram", "PromIndex",
                "PromLabels", "PromStorage", "PromWAL", "GoCompat",
            ]),

        // Phase 7: `tsdb/record` — the WAL's wire format. Byte-exact, exported and stateless, which
        // makes it the one piece of the write path that can be pinned before `head.go` or `wlog` exists.
        .target(
            name: "PromRecord",
            dependencies: [
                "PromLabels", "PromHistogram", "PromChunks", "PromEncoding", "PromStorage",
                "PromTombstones", "PromModel", "GoCompat",
            ]
        ),

        // Phase 6: a block's `meta.json` and the reader that ties the index and chunk readers together.
        .target(
            name: "PromBlock",
            dependencies: [
                "PromIndex", "PromChunks", "PromChunkEnc", "PromStorage", "PromEncoding", "PromFS",
                "PromLabels", "PromTombstones", "GoCompat",
            ]
        ),

        // Phase 6: `tsdb/index`'s postings algebra. `MemPostings` is deliberately not here — that is
        // the Head's in-memory index and belongs with the Head in Phase 7. See Postings.swift.
        .target(
            name: "PromIndex",
            dependencies: [
                "PromStorage", "PromLabels", "PromEncoding", "PromHash", "PromFS", "GoCompat",
            ]
        ),
        .target(
            name: "PromStorage",
            dependencies: [
                "PromLabels", "PromModel", "PromHistogram", "PromChunkEnc", "PromChunks",
                "PromAnnotations", "GoCompat",
            ]
        ),

        // Phase 4: the PromQL lexer and a hand-written parser replacing goyacc.
        .target(
            name: "PromQLParser",
            dependencies: [
                "PromModel", "PromLabels", "PromHistogram", "PromPosRange", "PromStorage",
                "GoCompat",
            ]
        ),

        // Phase 5: the engine's value types. `promql/value.go`; the evaluator
        // itself follows.
        .target(
            name: "PromQL",
            dependencies: [
                "PromQLParser", "PromStorage", "PromChunkEnc", "PromHistogram",
                "PromLabels", "PromSchema", "PromAnnotations", "PromModel", "GoCompat",
                // `label_replace` needs the capture-tracking VM and `ExpandString`.
                "PromRegex",
            ]
        ),

        // Phase 5: the in-memory `Queryable` the `.test` runner queries. Fills
        // `util/teststorage`'s role but is NOT a port of it — upstream's is a
        // wrapper over a real `tsdb.DB`, which Phases 6-7 own. Separate target
        // for the same reason upstream keeps `teststorage` out of `storage`, and
        // so that Phase 6 can swap the real Head in behind the same protocol.
        .target(
            name: "PromTestStorage",
            dependencies: [
                "PromStorage", "PromChunkEnc", "PromChunks", "PromHistogram",
                "PromLabels", "PromAnnotations", "GoCompat",
            ]
        ),

        // Phase 5: classic histogram samples -> one NHCB. The direction
        // `PromHistogram.convertNHCBToClassic` does not go, and what
        // `promqltest`'s `load_with_nhcb` needs — ~195 exit-gate assertions.
        // Its own target because Phase 8's scrape loop needs it too, and it
        // depends on nothing but the histogram and label models.
        .target(
            name: "PromConvertNHCB",
            dependencies: ["PromHistogram", "PromLabels", "PromModel", "GoCompat"]
        ),

        // Phase 5: the `.test` file runner — THE EXIT GATE. Unlike every other
        // target this one needs no differential corpus: the 2,183 `eval`
        // assertions in `Fixtures/promql/testdata/` are already upstream's, so
        // running them IS the verification. See Sources/PromQLTest/Runner.swift.
        .target(
            name: "PromQLTest",
            dependencies: [
                "PromQL", "PromQLParser", "PromTestStorage", "PromStorage",
                "PromChunks", "PromHistogram", "PromConvertNHCB", "PromLabels", "PromModel",
                // `expect fail regex:` and `expect … regex:` need an unanchored search, which the
                // capture VM provides.
                "PromRegex",
                "GoCompat",
            ]
        ),

        .testTarget(
            name: "PromConvertNHCBTests",
            dependencies: ["PromConvertNHCB", "PromHistogram", "GoOracleSupport", "GoCompat"]
        ),
        .testTarget(
            name: "PromQLTestTests",
            dependencies: ["PromQLTest", "PromQL", "PromQLParser", "GoOracleSupport", "GoCompat"]
        ),

        // ── Tooling ──────────────────────────────────────────────────────────
        .executableTarget(
            name: "promdiff",
            dependencies: [
                "GoCompat", "PromHash", "PromLabels", "PromEncoding", "PromRegex",
                "GoOracleSupport",
            ]
        ),

        // ── Tests ────────────────────────────────────────────────────────────
        // GoOracleSupport is a regular target, not a test target: `promdiff` links it
        // too, so it cannot live under Tests/.
        .target(name: "GoOracleSupport"),

        .testTarget(name: "GoCompatTests", dependencies: ["GoCompat", "GoOracleSupport"]),
        .testTarget(name: "PromHashTests", dependencies: ["PromHash", "GoOracleSupport"]),
        .testTarget(name: "PromMathTests", dependencies: ["PromMath", "GoOracleSupport"]),
        .testTarget(
            name: "PromModelTests",
            dependencies: ["PromModel", "GoCompat", "GoOracleSupport"]
        ),
        .testTarget(name: "PromRegexTests", dependencies: ["PromRegex", "GoOracleSupport"]),
        .testTarget(
            name: "PromHistogramTests",
            dependencies: ["PromHistogram", "PromLabels", "PromModel", "GoOracleSupport"]
        ),
        .testTarget(name: "PromLabelsTests", dependencies: ["PromLabels", "GoOracleSupport"]),
        .testTarget(
            name: "PromSchemaTests",
            dependencies: ["PromSchema", "PromLabels", "PromModel", "GoOracleSupport"]
        ),
        .testTarget(name: "PromEncodingTests", dependencies: ["PromEncoding", "GoOracleSupport"]),
        .testTarget(
            name: "PromAnnotationsTests",
            dependencies: ["PromAnnotations", "PromPosRange", "GoCompat", "GoOracleSupport"]
        ),
        .testTarget(
            name: "PromStorageTests",
            dependencies: [
                "PromStorage", "PromChunkEnc", "PromChunks", "PromHistogram", "PromLabels",
                "PromAnnotations", "PromModel", "GoCompat", "GoOracleSupport",
            ]
        ),
        .testTarget(
            name: "PromQLTests",
            dependencies: [
                "PromQL", "PromQLParser", "PromStorage", "PromChunkEnc", "PromChunks",
                "PromHistogram", "PromLabels", "PromModel", "GoCompat", "GoOracleSupport",
                // The selector corpus loads its series into the in-memory storage, the same
                // one PromTestStorageTests pins against a real tsdb.DB.
                "PromTestStorage",
            ]
        ),
        .testTarget(
            name: "PromQLParserTests",
            dependencies: [
                "PromQLParser", "PromHistogram", "PromLabels", "PromModel", "PromPosRange",
                "PromStorage", "GoCompat", "GoOracleSupport",
            ]
        ),
        .testTarget(
            name: "PromBlockTests",
            dependencies: [
                "PromBlock", "PromFS", "PromIndex", "PromChunks", "PromChunkEnc", "PromStorage",
                "PromTombstones", "GoOracleSupport", "GoCompat",
            ]
        ),
        .testTarget(
            name: "PromHeadTests",
            dependencies: [
                "PromHead", "PromChunkEnc", "PromChunks", "PromFS", "PromHistogram", "PromLabels",
                "GoOracleSupport", "GoCompat",
            ]
        ),
        .testTarget(
            name: "PromWALTests",
            dependencies: ["PromWAL", "PromFS", "PromHash", "PromRecord", "GoOracleSupport", "GoCompat"]
        ),
        .testTarget(
            name: "PromRecordTests",
            dependencies: [
                "PromRecord", "PromLabels", "PromHistogram", "PromChunks", "PromStorage",
                "PromTombstones", "PromModel", "GoOracleSupport", "GoCompat",
            ]
        ),
        .testTarget(
            name: "PromFSTests",
            dependencies: ["PromFS", "PromEncoding"]
        ),
        .testTarget(
            name: "PromChunksTests",
            dependencies: [
                "PromChunks", "PromChunkEnc", "PromHash", "PromFS", "GoOracleSupport", "GoCompat",
            ]
        ),
        .testTarget(
            name: "PromIndexTests",
            dependencies: [
                "PromIndex", "PromStorage", "PromEncoding", "PromFS", "GoOracleSupport", "GoCompat",
            ]
        ),
        .testTarget(
            name: "PromChunkEncTests",
            dependencies: ["PromChunkEnc", "PromHistogram", "PromModel", "GoOracleSupport"]
        ),
        .testTarget(
            name: "PromTestStorageTests",
            dependencies: [
                "PromTestStorage", "PromStorage", "PromChunkEnc", "PromChunks",
                "PromHistogram", "PromLabels", "PromAnnotations", "GoCompat",
                "GoOracleSupport",
            ]
        ),
    ]
)

for target in package.targets {
    var settings = target.swiftSettings ?? []
    settings.append(.swiftLanguageMode(.v6))
    settings.append(.enableUpcomingFeature("ExistentialAny"))
    settings.append(.enableUpcomingFeature("InternalImportsByDefault"))
    target.swiftSettings = settings
}
