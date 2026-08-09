//===----------------------------------------------------------------------===//
// Differential-testing support: load committed JSONL fixtures produced by the Go
// oracle, and (optionally) drive the oracle live.
//
// `swift test` is hermetic — it reads Fixtures/ and needs no Go toolchain.
// Scripts/verify-fixtures.sh regenerates and diffs to catch upstream drift.
//===----------------------------------------------------------------------===//

public import Foundation

/// One fixture case: an input, and the output Go produced for it.
public struct FixtureCase<In: Decodable & Sendable, Out: Decodable & Equatable & Sendable>:
    Decodable, Sendable
{
    public let id: String
    public let `in`: In
    public let out: Out
}

public enum FixtureError: Error, CustomStringConvertible {
    case notFound(String)
    case mismatches(path: String, total: Int, checked: Int, detail: String)

    public var description: String {
        switch self {
        case .notFound(let p):
            return """
                fixture not found: \(p)
                Run Scripts/regen-fixtures.sh (requires the Go oracle and the pinned worktree).
                """
        case .mismatches(let path, let total, let checked, let detail):
            return "\(path): \(total) of \(checked) cases mismatched\n\(detail)"
        }
    }
}

public enum Fixtures {

    /// Repository root, located by walking up from this source file. Keeps
    /// fixtures loadable without SwiftPM resource bundling, which would copy
    /// megabytes of JSONL into every test target.
    public static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        // Sources/GoOracleSupport/Fixture.swift -> repo root
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    public static var fixturesDirectory: URL {
        repositoryRoot.appendingPathComponent("Fixtures")
    }

    /// Load a JSONL fixture file, one case per line.
    public static func load<In: Decodable & Sendable, Out: Decodable & Equatable & Sendable>(
        _ relativePath: String,
        _: FixtureCase<In, Out>.Type = FixtureCase<In, Out>.self
    ) throws -> [FixtureCase<In, Out>] {
        let url = fixturesDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else {
            throw FixtureError.notFound(url.path)
        }
        let decoder = JSONDecoder()
        var cases = [FixtureCase<In, Out>]()
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            cases.append(try decoder.decode(FixtureCase<In, Out>.self, from: Data(line)))
        }
        return cases
    }

    /// Run `body` over every case and report **all** mismatches at once.
    ///
    /// Batch reporting is deliberate: corpora run to millions of cases, and
    /// stopping at the first failure hides whether a bug is systematic or a
    /// single edge case.
    ///
    /// Comparison is `==` over the decoded output, which for float-carrying
    /// fixtures means bit patterns. There is deliberately no tolerant variant: if
    /// a surface cannot match Go to the bit, that is a finding to chase or a
    /// documented exception, not something to paper over here.
    public static func check<In: Decodable & Sendable, Out: Decodable & Equatable & Sendable>(
        _ relativePath: String,
        _: FixtureCase<In, Out>.Type = FixtureCase<In, Out>.self,
        maxReported: Int = 20,
        _ body: (In) throws -> Out
    ) throws {
        let cases = try load(relativePath, FixtureCase<In, Out>.self)
        var failures = 0
        var detail = ""
        for c in cases {
            let got: Out
            do {
                got = try body(c.in)
            } catch {
                failures += 1
                if failures <= maxReported {
                    detail += "  [\(c.id)] threw \(error)\n"
                }
                continue
            }
            if got != c.out {
                failures += 1
                if failures <= maxReported {
                    detail += "  [\(c.id)]\n    got  \(got)\n    want \(c.out)\n"
                }
            }
        }
        if failures > 0 {
            if failures > maxReported {
                detail += "  ... and \(failures - maxReported) more\n"
            }
            throw FixtureError.mismatches(
                path: relativePath, total: failures, checked: cases.count, detail: detail)
        }
    }
}
