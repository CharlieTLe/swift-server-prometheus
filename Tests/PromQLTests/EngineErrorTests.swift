//===----------------------------------------------------------------------===//
// Differential tests for engine.go's error vocabulary and for `sort.Sort(Matrix)`.
//
// The errors are pinned because every one of these strings reaches the user through the
// HTTP API. The Matrix sort is pinned because `Matrix.Less` is *not* a total order across
// duplicate label sets, so the permutation there is `sort.Sort`'s and nobody else's — now
// reproducible, since `GoSort` exists. See oracle/suites_promql_engine_errors.go.
//===----------------------------------------------------------------------===//

import GoCompat
import GoOracleSupport
import PromAnnotations
import PromLabels
import PromPosRange
import Testing

@testable import PromQL

struct QueryErrIn: Decodable, Sendable {
    var kind: String
    var env: String
    var inner: String
    var cause: String
}

struct QueryErrOut: Decodable, Equatable, Sendable {
    var text: String
    var mapped: String
}

struct MatrixSortIn: Decodable, Sendable {
    var series: [[String]]
}

struct MatrixSortOut: Decodable, Equatable, Sendable {
    var perm: [Int]
}

/// A plain error carrying a message, standing in for Go's `errors.New`.
private struct TextError: Error, CustomStringConvertible {
    var description: String
}

/// Any real annotation will do: what is under test is whether the annotations SURVIVE the
/// error, not which one it is.
private func sampleWarning() -> any AnnotationError {
    newMixedFloatsHistogramsWarning("m", PositionRange(start: 0, end: 1))
}

@Suite("engine.go's query errors")
struct QueryErrorTests {

    @Test("every committed message matches Go")
    func errorsMatchGo() throws {
        try Fixtures.check("promql/queryerrors.jsonl", FixtureCase<QueryErrIn, QueryErrOut>.self) {
            input in
            switch input.kind {
            case "timeout":
                return QueryErrOut(
                    text: QueryError.queryTimeout(input.env).description, mapped: "")
            case "canceled":
                return QueryErrOut(
                    text: QueryError.queryCanceled(input.env).description, mapped: "")
            case "tooManySamples":
                return QueryErrOut(
                    text: QueryError.tooManySamples(input.env).description, mapped: "")
            case "storage":
                return QueryErrOut(
                    text: QueryError.storage(TextError(description: input.inner)).description,
                    mapped: "")
            case "withWarnings":
                var annos = Annotations()
                annos.add(sampleWarning())
                return QueryErrOut(
                    text: ErrWithWarnings(TextError(description: input.inner), annos)
                        .description,
                    mapped: "")
            case "contextErr":
                let cause: any Error
                switch input.cause {
                case "canceled", "wrappedCanceled":
                    // Go's `errors.Is` unwraps, so a wrapped `context.Canceled` still maps.
                    // `ContextCancellation` has no wrapping to model, so both arrive here.
                    cause = ContextCancellation.canceled
                case "deadline":
                    cause = ContextCancellation.deadlineExceeded
                default:
                    cause = TextError(description: input.inner)
                }
                let got = contextErr(cause, input.env)
                var mapped = "passthrough"
                if let q = got as? QueryError {
                    switch q {
                    case .queryCanceled: mapped = "canceled"
                    case .queryTimeout: mapped = "timeout"
                    default: mapped = "passthrough"
                    }
                }
                return QueryErrOut(text: String(describing: got), mapped: mapped)
            default:
                fatalError("unknown kind \(input.kind)")
            }
        }
    }
}

@Suite("sort.Sort(Matrix), whose comparator is not total across duplicates")
struct MatrixSortTests {

    @Test("every committed permutation matches Go")
    func matrixSortMatchesGo() throws {
        try Fixtures.check(
            "promql/matrixsort.jsonl", FixtureCase<MatrixSortIn, MatrixSortOut>.self
        ) { input in
            var mat = Matrix(
                input.series.enumerated().map { i, ls in
                    // The index rides along in the floats so the permutation is
                    // recoverable; `less` reads only the metric.
                    Series(metric: Labels(strings: ls), floats: [FPoint(t: 0, f: Double(i))])
                })
            mat.sort()
            return MatrixSortOut(perm: mat.series.map { Int($0.floats[0].f) })
        }
    }
}

// MARK: - Properties the fixtures state but do not explain

@Suite("query error invariants")
struct QueryErrorInvariantTests {

    @Test("the three timing errors name a place, not a duration")
    func locationsNotDurations() {
        // Reads oddly and is correct: the payload is where the query was, so an empty one
        // leaves a dangling "in ".
        #expect(
            QueryError.queryTimeout("expression evaluation").description
                == "query timed out in expression evaluation")
        #expect(QueryError.queryTimeout("").description == "query timed out in ")
        #expect(QueryError.queryCanceled("").description == "query was canceled in ")
        #expect(
            QueryError.tooManySamples("query execution").description
                == "query processing would load too many samples into memory in query execution")
    }

    @Test("ErrStorage is transparent — no prefix at all")
    func storageIsTransparent() {
        // `ErrStorage.Error()` is `e.Err.Error()`. Adding "storage: " would look tidier and
        // break every consumer matching on the text.
        struct Inner: Error, CustomStringConvertible { var description: String }
        #expect(
            QueryError.storage(Inner(description: "block not found")).description
                == "block not found")
    }

    @Test("a deadline is reported as a timeout, not as a deadline")
    func deadlineBecomesTimeout() {
        // contextErr's mapping is not symmetric with the names: DeadlineExceeded becomes
        // ErrQueryTimeout.
        let got = contextErr(ContextCancellation.deadlineExceeded, "query execution")
        #expect(String(describing: got) == "query timed out in query execution")
        let cancelled = contextErr(ContextCancellation.canceled, "query execution")
        #expect(String(describing: cancelled) == "query was canceled in query execution")
    }

    @Test("classifying an error preserves ErrWithWarnings' annotations")
    func warningsSurviveTheError() {
        // The only way a failed evaluation still returns warnings, and the reason the
        // ErrWithWarnings case has to be tested before the plain-error case.
        struct Inner: Error, CustomStringConvertible { var description: String }
        var carried = Annotations()
        carried.add(sampleWarning())

        var out = Annotations()
        let err = classifyEvaluationError(
            ErrWithWarnings(Inner(description: "the failure"), carried), warnings: &out)
        #expect(String(describing: err) == "the failure")
        #expect(!out.isEmpty)

        // A plain error carries nothing across.
        var none = Annotations()
        let plain = classifyEvaluationError(Inner(description: "plain"), warnings: &none)
        #expect(String(describing: plain) == "plain")
        #expect(none.isEmpty)
    }

    @Test("a runtime failure is wrapped with `unexpected error:`")
    func runtimeErrorsAreWrapped() {
        struct Inner: Error, CustomStringConvertible { var description: String }
        var annos = Annotations()
        let err = classifyEvaluationError(
            Inner(description: "index out of range"), warnings: &annos, isRuntimeError: true)
        #expect(String(describing: err) == "unexpected error: index out of range")
    }
}
