//===----------------------------------------------------------------------===//
// Wire types and the replay harness for the in-memory storage fixtures.
//
// Mirrors oracle/suites_storage_memselect.go and
// oracle/corpus_storage_memselect.go. Duplicated per target rather than shared,
// as every other *Wire.swift in this repo is.
//===----------------------------------------------------------------------===//

import Foundation
import GoOracleSupport
import PromChunkEnc
import PromChunks
import PromLabels
import PromStorage
import Testing

@testable import PromTestStorage

// MARK: - Wire

struct MemMatcherJSON: Decodable, Sendable {
    /// "=", "!=", "=~" or "!~".
    let type: String
    let name: String
    let value: String
}

struct MemSeriesInJSON: Decodable, Sendable {
    /// Flat name/value pairs.
    let labels: [String]
    let t: [String]
    let st: [String]
    /// Hex bit patterns.
    let f: [String]
}

struct MemHintsJSON: Decodable, Sendable {
    let start: String
    let end: String
    let disableTrimming: Bool
}

struct MemSelectIn: Decodable, Sendable {
    let series: [MemSeriesInJSON]
    let mint: String
    let maxt: String
    /// nil means Select is called with no hints at all.
    let hints: MemHintsJSON?
    let matchers: [MemMatcherJSON]
}

struct MemSampleOutJSON: Decodable, Equatable, Sendable {
    let t: String
    let st: String
    let f: String
    /// `ValueType` raw value.
    let type: Int
}

struct MemSeriesOutJSON: Decodable, Equatable, Sendable {
    let labels: String
    let samples: [MemSampleOutJSON]
}

struct MemSelectOut: Decodable, Equatable, Sendable {
    let series: [MemSeriesOutJSON]
    let err: String
    let warnings: [String]
}

struct MemLabelsIn: Decodable, Sendable {
    let series: [MemSeriesInJSON]
    let mint: String
    let maxt: String
    /// "names" or "values".
    let kind: String
    let name: String
    let limit: Int
    /// Optional: Go encodes a nil slice as `null`, and most cases here have no
    /// matchers at all.
    let matchers: [MemMatcherJSON]?
}

struct MemLabelsOut: Decodable, Equatable, Sendable {
    let result: [String]
    let err: String
    let warnings: [String]
}

// MARK: - Building

enum MemWire {
    static func i64(_ s: String) -> Int64 {
        guard let v = Int64(s) else {
            preconditionFailure("not an Int64: \(s)")
        }
        return v
    }

    static func float(_ hex: String) -> Double {
        guard let bits = UInt64(hex, radix: 16) else {
            preconditionFailure("not a hex bit pattern: \(hex)")
        }
        return Double(bitPattern: bits)
    }

    static func matchType(_ s: String) -> MatchType {
        switch s {
        case "=": return .equal
        case "!=": return .notEqual
        case "=~": return .regexp
        case "!~": return .notRegexp
        default: preconditionFailure("unknown match type \(s)")
        }
    }

    static func matchers(_ in_: [MemMatcherJSON]) throws -> [Matcher] {
        try in_.map { try Matcher(matchType($0.type), $0.name, $0.value) }
    }

    /// Loads the dataset in the order given, which is the append order the
    /// fixture's series list encodes.
    static func load(_ series: [MemSeriesInJSON]) throws -> MemStorage {
        let store = MemStorage()
        for s in series {
            let lset = Labels(strings: s.labels)
            var samples = [any Sample]()
            for i in s.t.indices {
                samples.append(
                    FSample(st: i64(s.st[i]), t: i64(s.t[i]), f: float(s.f[i])))
            }
            try store.load(lset, samples)
        }
        return store
    }

    /// Drains a `Series` into the fixture's output shape.
    static func drain(_ series: any PromStorage.Series) -> MemSeriesOutJSON {
        var samples = [MemSampleOutJSON]()
        let it = series.iterator(nil)
        while true {
            let vt = it.next()
            if vt == .none { break }
            let (t, f) = it.at()
            samples.append(
                MemSampleOutJSON(
                    t: String(t), st: String(it.atST()),
                    f: String(format: "%016llx", f.bitPattern), type: Int(vt.rawValue)))
        }
        return MemSeriesOutJSON(labels: series.labels().description, samples: samples)
    }
}
