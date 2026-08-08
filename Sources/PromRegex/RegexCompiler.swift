//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/regexp/syntax/compile.go, plus a Pike VM standing in
// for $GOROOT/src/regexp/exec.go.
//
// The VM is boolean-only and needs no capture tracking. That is not a shortcut:
// `Matcher.Matches` asks whether the WHOLE subject matches a fully anchored
// pattern, which is a language-membership question. Leftmost-first versus
// leftmost-longest, and submatch boundaries, cannot change the answer — so Go's
// onepass/backtrack/NFA machinery collapses to one simple simulation.
//
// It is an NFA simulation, so matching is linear in (pattern x input) with no
// backtracking. That is the property ADR-6 is about: these patterns come straight
// from user queries.
//===----------------------------------------------------------------------===//

/// Go: `patchList` — a linked list of instruction slots awaiting a target,
/// threaded through the unfilled `out`/`arg` fields themselves.
///
/// A value `head` denotes `inst[head>>1].out` when `head & 1 == 0`, else
/// `inst[head>>1].arg`. `head == 0` is the empty list, which is safe because
/// every program starts with a `fail` instruction whose output is never a target.
private struct PatchList {
    var head: UInt32 = 0
    var tail: UInt32 = 0

    static func make(_ n: UInt32) -> PatchList { PatchList(head: n, tail: n) }

    func patch(_ prog: inout RegexProgram, _ val: UInt32) {
        var head = self.head
        while head != 0 {
            let i = Int(head >> 1)
            if head & 1 == 0 {
                head = prog.inst[i].out
                prog.inst[i].out = val
            } else {
                head = prog.inst[i].arg
                prog.inst[i].arg = val
            }
        }
    }

    func appending(_ prog: inout RegexProgram, _ l2: PatchList) -> PatchList {
        if head == 0 { return l2 }
        if l2.head == 0 { return self }
        let i = Int(tail >> 1)
        if tail & 1 == 0 {
            prog.inst[i].out = l2.head
        } else {
            prog.inst[i].arg = l2.head
        }
        return PatchList(head: head, tail: l2.tail)
    }
}

/// Go: `frag` — a compiled program fragment.
private struct Frag {
    var i: UInt32 = 0
    var out = PatchList()
    /// Whether the fragment can match the empty string. Needed because `f*` must
    /// compile as `(f+)?` when f is nullable, to keep match priority correct
    /// (golang/go#46123).
    var nullable = false
}

/// Go: `syntax.Compile`. The regexp must already have been simplified.
public func compileRegex(_ re: Regexp) -> RegexProgram {
    var c = RegexCompiler()
    c.initProgram()
    let f = c.compile(re)
    let matchFrag = c.inst(.match)
    f.out.patch(&c.prog, matchFrag.i)
    c.prog.start = Int(f.i)
    return c.prog
}

private struct RegexCompiler {
    var prog = RegexProgram()

    static let anyRuneNotNL: [UInt32] = [0, 0x0A - 1, 0x0A + 1, 0x10FFFF]
    static let anyRune: [UInt32] = [0, 0x10FFFF]

    mutating func initProgram() {
        prog = RegexProgram()
        prog.numCap = 2  // implicit ( and ) for the whole match, $0
        _ = inst(.fail)
    }

    mutating func inst(_ op: InstOp) -> Frag {
        let f = Frag(i: UInt32(prog.inst.count), out: PatchList(), nullable: true)
        var i = Inst()
        i.op = op
        prog.inst.append(i)
        return f
    }

    mutating func compile(_ re: Regexp) -> Frag {
        switch re.op {
        case .noMatch:
            return Frag()  // fail
        case .emptyMatch:
            return nop()
        case .literal:
            if re.rune.isEmpty { return nop() }
            var f = Frag()
            for (j, r) in re.rune.enumerated() {
                let f1 = runeInst([r], re.flags)
                f = j == 0 ? f1 : cat(f, f1)
            }
            return f
        case .charClass:
            return runeInst(re.rune, re.flags)
        case .anyCharNotNL:
            return runeInst(Self.anyRuneNotNL, [])
        case .anyChar:
            return runeInst(Self.anyRune, [])
        case .beginLine:
            return empty(.beginLine)
        case .endLine:
            return empty(.endLine)
        case .beginText:
            return empty(.beginText)
        case .endText:
            return empty(.endText)
        case .wordBoundary:
            return empty(.wordBoundary)
        case .noWordBoundary:
            return empty(.noWordBoundary)
        case .capture:
            let bra = capInst(UInt32(re.cap << 1))
            let sub = compile(re.sub[0])
            let ket = capInst(UInt32(re.cap << 1 | 1))
            return cat(cat(bra, sub), ket)
        case .star:
            return star(compile(re.sub[0]), re.flags.contains(.nonGreedy))
        case .plus:
            return plus(compile(re.sub[0]), re.flags.contains(.nonGreedy))
        case .quest:
            return quest(compile(re.sub[0]), re.flags.contains(.nonGreedy))
        case .concat:
            if re.sub.isEmpty { return nop() }
            var f = Frag()
            for (i, sub) in re.sub.enumerated() {
                f = i == 0 ? compile(sub) : cat(f, compile(sub))
            }
            return f
        case .alternate:
            var f = Frag()
            for sub in re.sub { f = alt(f, compile(sub)) }
            return f
        case .repeat, .leftParen, .verticalBar:
            // Simplify() removes OpRepeat, and pseudo-ops never escape the parser.
            preconditionFailure("unhandled op in compile: \(re.op)")
        }
    }

    mutating func nop() -> Frag {
        var f = inst(.nop)
        f.out = PatchList.make(f.i << 1)
        return f
    }

    mutating func capInst(_ arg: UInt32) -> Frag {
        var f = inst(.capture)
        f.out = PatchList.make(f.i << 1)
        prog.inst[Int(f.i)].arg = arg
        if prog.numCap < Int(arg) + 1 { prog.numCap = Int(arg) + 1 }
        return f
    }

    mutating func cat(_ f1: Frag, _ f2: Frag) -> Frag {
        // Concatenation with failure is failure.
        if f1.i == 0 || f2.i == 0 { return Frag() }
        f1.out.patch(&prog, f2.i)
        return Frag(i: f1.i, out: f2.out, nullable: f1.nullable && f2.nullable)
    }

    mutating func alt(_ f1: Frag, _ f2: Frag) -> Frag {
        // Alternation with failure is the other branch.
        if f1.i == 0 { return f2 }
        if f2.i == 0 { return f1 }
        var f = inst(.alt)
        prog.inst[Int(f.i)].out = f1.i
        prog.inst[Int(f.i)].arg = f2.i
        f.out = f1.out.appending(&prog, f2.out)
        f.nullable = f1.nullable || f2.nullable
        return f
    }

    mutating func quest(_ f1: Frag, _ nongreedy: Bool) -> Frag {
        var f = inst(.alt)
        if nongreedy {
            prog.inst[Int(f.i)].arg = f1.i
            f.out = PatchList.make(f.i << 1)
        } else {
            prog.inst[Int(f.i)].out = f1.i
            f.out = PatchList.make(f.i << 1 | 1)
        }
        f.out = f.out.appending(&prog, f1.out)
        return f
    }

    /// Go: `loop` — the main loop of a plus or star.
    mutating func loop(_ f1: Frag, _ nongreedy: Bool) -> Frag {
        var f = inst(.alt)
        if nongreedy {
            prog.inst[Int(f.i)].arg = f1.i
            f.out = PatchList.make(f.i << 1)
        } else {
            prog.inst[Int(f.i)].out = f1.i
            f.out = PatchList.make(f.i << 1 | 1)
        }
        f1.out.patch(&prog, f.i)
        return f
    }

    mutating func star(_ f1: Frag, _ nongreedy: Bool) -> Frag {
        if f1.nullable {
            // (f1+)? keeps the priority match order correct — golang/go#46123.
            return quest(plus(f1, nongreedy), nongreedy)
        }
        return loop(f1, nongreedy)
    }

    mutating func plus(_ f1: Frag, _ nongreedy: Bool) -> Frag {
        Frag(i: f1.i, out: loop(f1, nongreedy).out, nullable: f1.nullable)
    }

    mutating func empty(_ op: EmptyOp) -> Frag {
        var f = inst(.emptyWidth)
        prog.inst[Int(f.i)].arg = UInt32(op.rawValue)
        f.out = PatchList.make(f.i << 1)
        return f
    }

    mutating func runeInst(_ r: [UInt32], _ flags: RegexFlags) -> Frag {
        var f = inst(.rune)
        f.nullable = false
        var i = prog.inst[Int(f.i)]
        i.rune = r
        var fl = flags.intersection(.foldCase)  // the only flag that matters here
        if r.count != 1 || UnicodeTables.simpleFold(r[0]) == r[0] {
            fl.remove(.foldCase)
        }
        i.arg = UInt32(fl.rawValue)

        // Specialisations the matcher can exploit.
        if !fl.contains(.foldCase) && (r.count == 1 || (r.count == 2 && r[0] == r[1])) {
            i.op = .rune1
        } else if r.count == 2 && r[0] == 0 && r[1] == 0x10FFFF {
            i.op = .runeAny
        } else if r.count == 4 && r[0] == 0 && r[1] == 0x0A - 1 && r[2] == 0x0A + 1
            && r[3] == 0x10FFFF
        {
            i.op = .runeAnyNotNL
        }
        prog.inst[Int(f.i)] = i
        f.out = PatchList.make(f.i << 1)
        return f
    }
}

// MARK: - Pike VM

/// A boolean NFA simulation over a compiled program.
///
/// No captures, no leftmost-first/longest distinction: the only question asked is
/// whether a match exists, which those notions cannot change. Linear time in
/// program size times input length, with no backtracking.
public struct RegexMachine: Sendable {

    private let prog: RegexProgram

    public init(_ prog: RegexProgram) { self.prog = prog }

    /// Whether the program matches somewhere in `runes`.
    ///
    /// Prometheus always compiles `^(?s:...)$`, so the anchors are inside the
    /// program and this reports a full match.
    public func matches(_ runes: [UInt32]) -> Bool {
        var clist = ThreadList(capacity: prog.inst.count)
        var nlist = ThreadList(capacity: prog.inst.count)

        var pos = 0
        var before: Int32 = -1  // rune before pos, -1 at the beginning of text

        // Seed the start state with the correct zero-width context.
        let firstAfter: Int32 = runes.isEmpty ? -1 : Int32(bitPattern: runes[0])
        if addThread(&clist, prog.start, before, firstAfter) { return true }

        while true {
            if clist.isEmpty { return false }

            if pos >= runes.count { break }
            let r = runes[pos]
            let nextAfter: Int32 =
                pos + 1 < runes.count ? Int32(bitPattern: runes[pos + 1]) : -1

            nlist.reset()
            for pc in clist.dense {
                let i = prog.inst[pc]
                switch i.op {
                case .rune, .rune1, .runeAny, .runeAnyNotNL:
                    if matchesRune(i, r) {
                        if addThread(&nlist, Int(i.out), Int32(bitPattern: r), nextAfter) {
                            return true
                        }
                    }
                default:
                    break
                }
            }
            swap(&clist, &nlist)
            before = Int32(bitPattern: r)
            pos += 1
        }

        // Unreachable in practice: addThread returns as soon as it reaches a match
        // instruction, and it ran with after == -1 at the end so `$`/`\z` were
        // already honoured. Kept as a belt-and-braces check.
        return clist.dense.contains { prog.inst[$0].op == .match }
    }

    /// Convenience for a Swift string subject.
    public func matches(_ s: String) -> Bool {
        matches(s.unicodeScalars.map(\.value))
    }

    private func matchesRune(_ i: Inst, _ r: UInt32) -> Bool {
        switch i.op {
        case .rune1: return i.rune[0] == r
        case .runeAny: return true
        case .runeAnyNotNL: return r != 0x0A
        default: return i.matchRune(r)
        }
    }

    /// Adds `pc` and its epsilon closure to `list`. Returns true if a match
    /// instruction was reached, which for a boolean result ends the search.
    private func addThread(
        _ list: inout ThreadList, _ pc0: Int, _ before: Int32, _ after: Int32
    ) -> Bool {
        var stack = [pc0]
        while let pc = stack.popLast() {
            if pc == 0 { continue }  // the leading fail instruction
            if list.contains(pc) { continue }
            list.insert(pc)
            let i = prog.inst[pc]
            switch i.op {
            case .fail:
                continue
            case .alt, .altMatch:
                // Push arg first so out is explored first; order is irrelevant to
                // a boolean result but keeps the traversal predictable.
                stack.append(Int(i.arg))
                stack.append(Int(i.out))
            case .nop, .capture:
                // Captures are not tracked; treat as a no-op.
                stack.append(Int(i.out))
            case .emptyWidth:
                if i.matchEmptyWidth(before, after) {
                    stack.append(Int(i.out))
                }
            case .match:
                return true
            case .rune, .rune1, .runeAny, .runeAnyNotNL:
                break  // consumes input; handled by the caller's step
            }
        }
        return false
    }
}

/// A sparse set of program counters, reset in O(1) per step.
private struct ThreadList {
    var dense: [Int] = []
    private var sparse: [Int]
    private var generation: [Int]
    private var gen = 0

    init(capacity: Int) {
        sparse = [Int](repeating: 0, count: capacity)
        generation = [Int](repeating: -1, count: capacity)
        dense.reserveCapacity(capacity)
    }

    var isEmpty: Bool { dense.isEmpty }

    func contains(_ pc: Int) -> Bool { generation[pc] == gen }

    mutating func insert(_ pc: Int) {
        generation[pc] = gen
        sparse[pc] = dense.count
        dense.append(pc)
    }

    mutating func reset() {
        gen += 1
        dense.removeAll(keepingCapacity: true)
    }
}
