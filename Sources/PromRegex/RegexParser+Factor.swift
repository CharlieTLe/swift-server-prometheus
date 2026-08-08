//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/regexp/syntax/parse.go — `factor` and its helpers.
//
// factor rewrites an alternation by pulling out common prefixes:
//
//     ABC|ABD|AEF|BCX|BCY
//  -> A(B(C|D)|EF)|BC(X|Y)      (literal prefix extraction)
//  -> A(B[CD]|EF)|BC[XY]        (character class introduction)
//
// This is not cosmetic — it changes the tree Prometheus sees, and
// `findSetMatches` walks that tree, so the factored shape is observable through
// SetMatches.
//===----------------------------------------------------------------------===//

extension RegexParser {

    /// Go: `factor`.
    mutating func factor(_ subIn: [Regexp]) -> [Regexp] {
        if subIn.count < 2 { return subIn }
        var sub = subIn

        // Round 1: factor out common literal prefixes.
        var str: [UInt32] = []
        var strflags: RegexFlags = []
        var start = 0
        var out = [Regexp]()
        for i in 0...sub.count {
            // Invariant: sub[start..<i] all begin with `str` under `strflags`.
            var istr: [UInt32] = []
            var iflags: RegexFlags = []
            if i < sub.count {
                (istr, iflags) = Self.leadingString(sub[i])
                if iflags == strflags {
                    var same = 0
                    while same < str.count && same < istr.count && str[same] == istr[same] {
                        same += 1
                    }
                    if same > 0 {
                        // Still sharing a prefix; keep accumulating.
                        str = Array(str[0..<same])
                        continue
                    }
                }
            }

            // End of a run sharing a leading literal.
            if i == start {
                // Nothing to do.
            } else if i == start + 1 {
                out.append(sub[start])  // just one; not worth factoring
            } else {
                let prefix = makeRegexp(.literal)
                prefix.flags = strflags
                prefix.rune = str

                for j in start..<i {
                    sub[j] = removeLeadingString(sub[j], str.count)
                }
                let suffix = collapse(Array(sub[start..<i]), .alternate)  // recurse

                let re = makeRegexp(.concat)
                re.sub = [prefix, suffix]
                out.append(re)
            }

            start = i
            str = istr
            strflags = iflags
        }
        sub = out

        // Round 2: factor out a common simple prefix — just the first piece of
        // each concatenation. Complex subexpressions (quantifiers) are NOT safe to
        // factor, because doing so collapses distinct paths through the automaton
        // and changes what matches.
        start = 0
        out = []
        var first: Regexp? = nil
        for i in 0...sub.count {
            var ifirst: Regexp? = nil
            if i < sub.count {
                ifirst = Self.leadingRegexp(sub[i])
                if let f = first, let g = ifirst, f.isEqual(to: g),
                    // The prefix must be a char class, or a fixed repeat of one.
                    Self.isCharClassNode(f)
                        || (f.op == .repeat && f.min == f.max && Self.isCharClassNode(f.sub[0]))
                {
                    continue
                }
            }

            if i == start {
                // Nothing to do.
            } else if i == start + 1 {
                out.append(sub[start])
            } else {
                let prefix = first!
                for j in start..<i {
                    sub[j] = removeLeadingRegexp(sub[j])
                }
                let suffix = collapse(Array(sub[start..<i]), .alternate)  // recurse

                let re = makeRegexp(.concat)
                re.sub = [prefix, suffix]
                out.append(re)
            }

            start = i
            first = ifirst
        }
        sub = out

        // Round 3: collapse runs of single literals into character classes.
        start = 0
        out = []
        for i in 0...sub.count {
            if i < sub.count, Self.isCharClassNode(sub[i]) { continue }

            if i == start {
                // Nothing to do.
            } else if i == start + 1 {
                out.append(sub[start])
            } else {
                // Merge into the most complex node in the run.
                var maxIdx = start
                for j in (start + 1)..<i {
                    if sub[maxIdx].op < sub[j].op
                        || (sub[maxIdx].op == sub[j].op
                            && sub[maxIdx].rune.count < sub[j].rune.count)
                    {
                        maxIdx = j
                    }
                }
                sub.swapAt(start, maxIdx)
                for j in (start + 1)..<i {
                    Self.mergeCharClassNode(sub[start], sub[j])
                }
                Self.cleanAltNode(sub[start])
                out.append(sub[start])
            }

            if i < sub.count { out.append(sub[i]) }
            start = i + 1
        }
        sub = out

        // Round 4: collapse runs of empty matches into one.
        out = []
        for i in 0..<sub.count {
            if i + 1 < sub.count, sub[i].op == .emptyMatch, sub[i + 1].op == .emptyMatch {
                continue
            }
            out.append(sub[i])
        }
        return out
    }

    /// Go: `leadingString`.
    static func leadingString(_ reIn: Regexp) -> ([UInt32], RegexFlags) {
        var re = reIn
        if re.op == .concat, !re.sub.isEmpty { re = re.sub[0] }
        if re.op != .literal { return ([], []) }
        return (re.rune, re.flags.intersection(.foldCase))
    }

    /// Go: `removeLeadingString`.
    mutating func removeLeadingString(_ reIn: Regexp, _ n: Int) -> Regexp {
        let re = reIn
        if re.op == .concat, !re.sub.isEmpty {
            // Removing a leading string may simplify the concatenation.
            let sub = removeLeadingString(re.sub[0], n)
            re.sub[0] = sub
            if sub.op == .emptyMatch {
                switch re.sub.count {
                case 0, 1:
                    // Not reachable in practice, but Go handles it.
                    re.op = .emptyMatch
                    re.sub = []
                case 2:
                    return re.sub[1]
                default:
                    re.sub.removeFirst()
                }
            }
            return re
        }
        if re.op == .literal {
            re.rune = Array(re.rune.dropFirst(n))
            if re.rune.isEmpty { re.op = .emptyMatch }
        }
        return re
    }

    /// Go: `leadingRegexp`.
    static func leadingRegexp(_ re: Regexp) -> Regexp? {
        if re.op == .emptyMatch { return nil }
        if re.op == .concat, !re.sub.isEmpty {
            let sub = re.sub[0]
            if sub.op == .emptyMatch { return nil }
            return sub
        }
        return re
    }

    /// Go: `removeLeadingRegexp`. The `reuse` flag is dropped along with pooling.
    mutating func removeLeadingRegexp(_ reIn: Regexp) -> Regexp {
        let re = reIn
        if re.op == .concat, !re.sub.isEmpty {
            re.sub.removeFirst()
            switch re.sub.count {
            case 0:
                re.op = .emptyMatch
                re.sub = []
            case 1:
                return re.sub[0]
            default:
                break
            }
            return re
        }
        return makeRegexp(.emptyMatch)
    }
}
