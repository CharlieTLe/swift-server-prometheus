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
        .library(name: "PromLabels", targets: ["PromLabels"]),
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
        .target(name: "PromHistogram", dependencies: ["PromModel", "PromMath", "GoCompat"]),
        .target(
            name: "PromLabels",
            dependencies: ["PromModel", "PromHash", "PromRegex", "GoCompat"]
        ),

        // ── Tier 2 ───────────────────────────────────────────────────────────
        .target(name: "PromEncoding", dependencies: ["PromHash", "GoCompat"]),

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
        .testTarget(name: "PromModelTests", dependencies: ["PromModel", "GoOracleSupport"]),
        .testTarget(name: "PromRegexTests", dependencies: ["PromRegex", "GoOracleSupport"]),
        .testTarget(
            name: "PromHistogramTests", dependencies: ["PromHistogram", "GoOracleSupport"]),
        .testTarget(name: "PromLabelsTests", dependencies: ["PromLabels", "GoOracleSupport"]),
        .testTarget(name: "PromEncodingTests", dependencies: ["PromEncoding", "GoOracleSupport"]),
    ]
)

for target in package.targets {
    var settings = target.swiftSettings ?? []
    settings.append(.swiftLanguageMode(.v6))
    settings.append(.enableUpcomingFeature("ExistentialAny"))
    settings.append(.enableUpcomingFeature("InternalImportsByDefault"))
    target.swiftSettings = settings
}
