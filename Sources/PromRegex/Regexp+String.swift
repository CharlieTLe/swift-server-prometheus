//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/regexp/syntax/regexp.go — String(), calcFlags,
// writeRegexp, escape.
//
// This is an observable surface, not a debugging aid: Prometheus compiles
// `"^(?s:" + parsed.String() + ")$"`, so the rendering feeds straight back into
// the matcher (model/labels/regexp.go:76 @ v3.13.2).
//===----------------------------------------------------------------------===//

private import GoCompat

/// Go: `printFlags` — which flags (and non-capturing parens) to print around a node.
private struct PrintFlags: OptionSet {
    var rawValue: UInt8

    static let i = PrintFlags(rawValue: 1 << 0)  // (?i:
    static let m = PrintFlags(rawValue: 1 << 1)  // (?m:
    static let s = PrintFlags(rawValue: 1 << 2)  // (?s:
    static let off = PrintFlags(rawValue: 1 << 3)  // )
    static let prec = PrintFlags(rawValue: 1 << 4)  // (?: )

    /// Go: `negShift` — `flagI << negShift` means `(?-i:`.
    static let negShift: UInt8 = 5

    var negated: PrintFlags { PrintFlags(rawValue: rawValue << PrintFlags.negShift) }
}

extension Regexp: CustomStringConvertible {

    /// Go: `(*Regexp).String()`.
    public var description: String {
        var flags = [ObjectIdentifier: PrintFlags]()
        var (must, cant) = Regexp.calcFlags(self, &flags)
        // Go: must |= (cant &^ flagI) << negShift
        must.formUnion(cant.subtracting(.i).negated)
        if !must.isEmpty { must.insert(.off) }
        var out = ""
        Regexp.write(&out, self, must, flags)
        return out
    }

    // MARK: - calcFlags

    /// Go: `addSpan` — enable `f` around `start...last`.
    private static func addSpan(
        _ start: Regexp, _ last: Regexp, _ f: PrintFlags,
        _ flags: inout [ObjectIdentifier: PrintFlags]
    ) {
        flags[ObjectIdentifier(start)] = f
        flags[ObjectIdentifier(last), default: []].insert(.off)  // start may == last
    }

    /// Go: `calcFlags` — returns the flags that must, and cannot, be active
    /// around `re`, recording per-subexpression spans in `flags`.
    private static func calcFlags(
        _ re: Regexp, _ flags: inout [ObjectIdentifier: PrintFlags]
    ) -> (must: PrintFlags, cant: PrintFlags) {
        switch re.op {
        case .literal:
            // Fold-sensitive literal: report (?i) as required or forbidden
            // depending on whether folding is active.
            for r in re.rune {
                if UnicodeTables.minFold <= r, r <= UnicodeTables.maxFold,
                    UnicodeTables.simpleFold(r) != r
                {
                    return re.flags.contains(.foldCase) ? (.i, []) : ([], .i)
                }
            }
            return ([], [])

        case .charClass:
            // Folding has already been compiled into the ranges, so (?i) must not
            // be printed if any fold-equivalent rune is missing from the class.
            var i = 0
            while i + 1 < re.rune.count {
                let lo = Swift.max(UnicodeTables.minFold, re.rune[i])
                let hi = Swift.min(UnicodeTables.maxFold, re.rune[i + 1])
                var r = lo
                while r <= hi {
                    var f = UnicodeTables.simpleFold(r)
                    while f != r {
                        if !(lo <= f && f <= hi) && !inCharClass(f, re.rune) {
                            return ([], .i)
                        }
                        f = UnicodeTables.simpleFold(f)
                    }
                    if r == UInt32.max { break }
                    r += 1
                }
                i += 2
            }
            return ([], [])

        case .anyCharNotNL: return ([], .s)  // (?-s).
        case .anyChar: return (.s, [])  // (?s).
        case .beginLine, .endLine: return (.m, [])  // (?m)^ (?m)$
        case .endText:
            return re.flags.contains(.wasDollar) ? ([], .m) : ([], [])  // (?-m)$

        case .capture, .star, .plus, .quest, .repeat:
            return calcFlags(re.sub[0], &flags)

        case .concat, .alternate:
            // Accumulate per-subexpression must/cant; on a conflict, wrap the span
            // identified so far and start over.
            var must: PrintFlags = []
            var cant: PrintFlags = []
            var allCant: PrintFlags = []
            var start = 0
            var last = 0
            var did = false
            for (i, sub) in re.sub.enumerated() {
                let (subMust, subCant) = calcFlags(sub, &flags)
                if !must.intersection(subCant).isEmpty || !subMust.intersection(cant).isEmpty {
                    if !must.isEmpty {
                        addSpan(re.sub[start], re.sub[last], must, &flags)
                    }
                    must = []
                    cant = []
                    start = i
                    did = true
                }
                must.formUnion(subMust)
                cant.formUnion(subCant)
                allCant.formUnion(subCant)
                if !subMust.isEmpty { last = i }
                if must.isEmpty && start == i { start += 1 }
            }
            if !did {
                // No conflicts: pass the accumulation upward.
                return (must, cant)
            }
            if !must.isEmpty {
                addSpan(re.sub[start], re.sub[last], must, &flags)
            }
            return ([], allCant)

        default:
            return ([], [])
        }
    }

    /// Go: `inCharClass`.
    private static func inCharClass(_ r: UInt32, _ ranges: [UInt32]) -> Bool {
        var lo = 0
        var hi = ranges.count / 2
        while lo < hi {
            let m = lo + (hi - lo) / 2
            if ranges[2 * m] <= r {
                if r <= ranges[2 * m + 1] { return true }
                lo = m + 1
            } else {
                hi = m
            }
        }
        return false
    }

    // MARK: - writeRegexp

    /// Go: `writeRegexp`.
    private static func write(
        _ b: inout String, _ re: Regexp, _ f0: PrintFlags,
        _ flags: [ObjectIdentifier: PrintFlags]
    ) {
        var f = f0
        f.formUnion(flags[ObjectIdentifier(re)] ?? [])

        if f.contains(.prec), !f.subtracting([.off, .prec]).isEmpty, f.contains(.off) {
            // flagPrec is redundant when other flags are being opened and closed.
            f.remove(.prec)
        }
        if !f.subtracting([.off, .prec]).isEmpty {
            b += "(?"
            if f.contains(.i) { b += "i" }
            if f.contains(.m) { b += "m" }
            if f.contains(.s) { b += "s" }
            let negMS = PrintFlags([.m, .s]).negated
            if !f.intersection(negMS).isEmpty {
                b += "-"
                if !f.intersection(PrintFlags.m.negated).isEmpty { b += "m" }
                if !f.intersection(PrintFlags.s.negated).isEmpty { b += "s" }
            }
            b += ":"
        }

        // Go uses `defer` for these closers; collect and append at the end.
        var closers = ""
        if f.contains(.off) { closers += ")" }
        if f.contains(.prec) {
            b += "(?:"
            closers += ")"
        }

        switch re.op {
        case .leftParen, .verticalBar:
            // Pseudo-ops live only on the parse stack and never reach a returned
            // tree; Go's printer has no case for them either.
            b += "<invalid op\(re.op.rawValue)>"
        case .noMatch:
            b += #"[^\x00-\x{10FFFF}]"#
        case .emptyMatch:
            b += "(?:)"
        case .literal:
            for r in re.rune { escape(&b, r, force: false) }
        case .charClass:
            writeCharClass(&b, re)
        case .anyCharNotNL, .anyChar:
            b += "."
        case .beginLine:
            b += "^"
        case .endLine:
            b += "$"
        case .beginText:
            b += #"\A"#
        case .endText:
            b += re.flags.contains(.wasDollar) ? "$" : #"\z"#
        case .wordBoundary:
            b += #"\b"#
        case .noWordBoundary:
            b += #"\B"#
        case .capture:
            if !re.name.isEmpty {
                b += "(?P<" + re.name + ">"
            } else {
                b += "("
            }
            if re.sub[0].op != .emptyMatch {
                write(&b, re.sub[0], flags[ObjectIdentifier(re.sub[0])] ?? [], flags)
            }
            b += ")"
        case .star, .plus, .quest, .repeat:
            var p: PrintFlags = []
            let sub = re.sub[0]
            if sub.op > .capture || (sub.op == .literal && sub.rune.count > 1) {
                p = .prec
            }
            write(&b, sub, p, flags)
            switch re.op {
            case .star: b += "*"
            case .plus: b += "+"
            case .quest: b += "?"
            case .repeat:
                b += "{\(re.min)"
                if re.max != re.min {
                    b += ","
                    if re.max >= 0 { b += "\(re.max)" }
                }
                b += "}"
            default: break
            }
            if re.flags.contains(.nonGreedy) { b += "?" }
        case .concat:
            for sub in re.sub {
                write(&b, sub, sub.op == .alternate ? .prec : [], flags)
            }
        case .alternate:
            for (i, sub) in re.sub.enumerated() {
                if i > 0 { b += "|" }
                write(&b, sub, [], flags)
            }
        }

        b += closers
    }

    private static func writeCharClass(_ b: inout String, _ re: Regexp) {
        if re.rune.count % 2 != 0 {
            b += "[invalid char class]"
            return
        }
        b += "["
        if re.rune.isEmpty {
            b += #"^\x00-\x{10FFFF}"#
        } else if re.rune[0] == 0 && re.rune[re.rune.count - 1] == 0x10FFFF && re.rune.count > 2 {
            // Spans 0 and MaxRune, so it is probably a negated class: print the gaps.
            b += "^"
            var i = 1
            while i < re.rune.count - 1 {
                let lo = re.rune[i] + 1
                let hi = re.rune[i + 1] - 1
                escape(&b, lo, force: lo == UInt32(UInt8(ascii: "-")))
                if lo != hi {
                    if hi != lo + 1 { b += "-" }
                    escape(&b, hi, force: hi == UInt32(UInt8(ascii: "-")))
                }
                i += 2
            }
        } else {
            var i = 0
            while i < re.rune.count {
                let lo = re.rune[i]
                let hi = re.rune[i + 1]
                escape(&b, lo, force: lo == UInt32(UInt8(ascii: "-")))
                if lo != hi {
                    if hi != lo + 1 { b += "-" }
                    escape(&b, hi, force: hi == UInt32(UInt8(ascii: "-")))
                }
                i += 2
            }
        }
        b += "]"
    }

    /// Go: `escape`. `meta` is the set of characters needing a backslash.
    private static let meta = Set(#"\.+*?()|[]{}^$"#.unicodeScalars.map { $0.value })

    private static func escape(_ b: inout String, _ r: UInt32, force: Bool) {
        if GoStrconv.isPrint(r) {
            if meta.contains(r) || force { b += "\\" }
            b.unicodeScalars.append(Unicode.Scalar(r) ?? "\u{FFFD}")
            return
        }
        switch r {
        case 0x07: b += #"\a"#
        case 0x0C: b += #"\f"#
        case 0x0A: b += #"\n"#
        case 0x0D: b += #"\r"#
        case 0x09: b += #"\t"#
        case 0x0B: b += #"\v"#
        default:
            if r < 0x100 {
                let s = String(r, radix: 16)
                b += #"\x"# + (s.count == 1 ? "0" : "") + s
            } else {
                b += #"\x{"# + String(r, radix: 16) + "}"
            }
        }
    }
}
