# swift-server-prometheus

A source-level port of the [Prometheus](https://github.com/prometheus/prometheus) monitoring server
from Go to Swift, pinned to upstream **v3.13.2**.

> **Status: early. Phase 1 of 10 complete.** The foundations and the differential-testing rig are in
> place and green. There is no server, no storage engine and no query engine yet.
> See [docs/ROADMAP.md](docs/ROADMAP.md).

## Why this exists

Prometheus is ~335k lines of non-test Go. Porting it is only meaningful if the result is
*verifiably* the same, so the project's organising constraint is **byte-exactness**: on-disk formats
identical, PromQL results identical bit-for-bit, error strings identical. That constraint is what
drives nearly every design decision here — see [docs/PORTING.md](docs/PORTING.md) for the contract
(including its deliberate exceptions) and [docs/DECISIONS.md](docs/DECISIONS.md) for the ADRs.

## How correctness is defined

Not by hand-written expectations. `oracle/` is a separate Go module that runs the pinned Prometheus
and Go toolchains and emits golden fixtures; `Fixtures/` holds **~70k committed cases**. `swift test`
reads those and needs no Go toolchain.

```sh
swift test                      # hermetic: reads committed Fixtures/
./Scripts/regen-fixtures.sh     # needs Go + the pinned upstream worktree
./Scripts/verify-fixtures.sh    # regenerate and diff — catches upstream drift
```

Adding a new byte-exact surface means adding an oracle subcommand and a fixture file, not writing
expected values by hand.

`Fixtures/promql/testdata/` holds the 21 upstream PromQL conformance files verbatim — ~2,200 `eval`
assertions. Those are the acceptance gate for the query engine in Phase 5, and the reason the roadmap
does PromQL before the storage engine: it is the only half of Prometheus that ships a portable oracle.

## What works today

| Module | Verified against Go |
|---|---|
| `GoCompat` | `strconv.FormatFloat` (`f/e/E/g/G`), `ParseFloat`, `Quote`/`Unquote`, `encoding/binary` varints, `time.Duration.String` |
| `PromHash` | xxhash64, CRC-32C |
| `PromMath` | Kahan–Neumaier summation (bit-exact), `almost.Equal` |
| `PromModel` | `StaleNaN` payloads, label/metric-name validation |
| `PromLabels` | packed encoding, `Hash`/`StableHash`, ordering, `String()`, `Builder`/`ScratchBuilder`, `Matcher`, OpenMetrics floats |
| `PromEncoding` | `ByteSlice`, `Encbuf`, `Decbuf` |

Regex matching is deliberately incomplete: `Matcher` accepts only literals and literal alternations
and **throws** otherwise, rather than silently substituting ICU semantics for RE2. Phase 2 fixes this.

Float formatting additionally cleared 4.8M differential cases with zero mismatches. Swift's
`Double.description` does **not** match Go's `strconv` — that divergence reaches PromQL output,
`labels.String()` and the HTTP API, so ported code must never use it (ADR-4).

## Building

Requires Swift 6.1+ (developed on 6.4, macOS arm64). Phase 1 has no external dependencies;
swift-server packages (NIO, Hummingbird, ServiceLifecycle, …) arrive with the phases that need them.

```sh
swift build && swift test
```

To regenerate fixtures you also need Go 1.25+ and the pinned upstream worktree:

```sh
git clone https://github.com/prometheus/prometheus.git ../../prometheus/prometheus
git -C ../../prometheus/prometheus worktree add ../prometheus-v3.13.2 v3.13.2
```

## Licensing

Apache 2.0, matching upstream. This is a derivative work of three differently-licensed sources —
Prometheus (Apache 2.0), the Go standard library (BSD 3-Clause), and cespare/xxhash (MIT). See
[NOTICE](NOTICE); every ported file names its origin in a header comment.

Not affiliated with the Prometheus project or the [swift-server](https://github.com/swift-server)
organisation.
