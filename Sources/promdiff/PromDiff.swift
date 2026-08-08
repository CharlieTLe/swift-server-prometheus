//===----------------------------------------------------------------------===//
// promdiff — the fuzz differ.
//
// Generates candidate inputs, asks the Go oracle for the answer, and diffs.
// Divergences it finds get promoted into committed fixtures. Requires the Go
// oracle to be built; `swift test` never depends on this.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromEncoding
import PromHash
import PromLabels

@main
struct PromDiff {
    static func main() {
        // Phase 1 placeholder: the generators land with the oracle subcommands in
        // Scripts/fuzz-diff.sh. Keeping the target in the build from the start so
        // it never rots.
        print("promdiff: no generators registered yet — see Scripts/fuzz-diff.sh")
    }
}
