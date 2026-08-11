//===----------------------------------------------------------------------===//
// Ported from $GOROOT/src/regexp/exec.go — the capture-tracking Pike VM, plus
// $GOROOT/src/regexp/regexp.go's `FindStringSubmatchIndex` and `expand`.
//
// **The other VM is boolean and stays that way.** `RegexCompiler.swift`'s machine answers "does the
// whole subject match", for which leftmost-first versus leftmost-longest and submatch boundaries
// cannot change the answer — so it needs none of this. `label_replace` asks a different question:
// *where* did each group match, so the replacement template can be expanded. That needs priority
// order, per-thread capture slots, and byte offsets, which is a different simulation rather than a
// flag on the old one.
//
// ## Offsets are BYTES, and that is not incidental
//
// Go's `FindStringSubmatchIndex` returns indices into the string's bytes, and `ExpandString` slices
// the subject with them. A rune-indexed port would agree on ASCII and silently disagree on the first
// non-ASCII label value — so this machine walks a `[UInt8]`, decodes runes as it steps, and records
// byte positions. ADR-9's rule applied to an internal index rather than to a public signature.
//
// ## Priority order IS the dense array's order
//
// `add` recurses into `out` before `arg`, so a thread's position in `dense` is its priority. On a
// match in first-match mode (which is Go's default; only `POSIX` wants longest) `step` **truncates
// the queue**, cutting every lower-priority thread. That truncation is what makes the result
// leftmost-first rather than leftmost-longest, and it is the one line that a "just track captures"
// rewrite of the boolean VM would omit.
//
// ## Captures are saved and restored around the recursive add
//
// `InstCapture` writes `cap[arg] = pos`, recurses, then puts the old value back. Without the restore,
// a capture set on one branch of an alternation leaks into the sibling branch. Go passes the array by
// slice and mutates in place, so the save/restore is load-bearing there; the port does the same on an
// `inout` array for the same reason.
//===----------------------------------------------------------------------===//

/// Go: `machine`, specialised to the one question `label_replace` asks.
public struct RegexCaptureMachine: Sendable {
    private let prog: RegexProgram

    public init(_ prog: RegexProgram) { self.prog = prog }

    /// Go: `Regexp.FindStringSubmatchIndex` — `nil` if there is no match, otherwise `2*(n+1)` byte
    /// offsets, where a `-1` pair marks a group that did not participate.
    public func findSubmatchIndex(_ bytes: [UInt8]) -> [Int]? {
        let ncap = Swift.max(prog.numCap, 2)
        var matchcap = [Int](repeating: -1, count: ncap)
        var matched = false

        var runq = CaptureQueue(capacity: prog.inst.count, ncap: ncap)
        var nextq = CaptureQueue(capacity: prog.inst.count, ncap: ncap)

        // Go's `input.step`: the rune at a byte position and its width. `endOfText` is -1.
        func step(_ pos: Int) -> (Int32, Int) {
            guard pos < bytes.count else { return (-1, 0) }
            return decodeRune(bytes, pos)
        }

        var pos = 0
        var (r, width) = step(pos)
        var (r1, width1): (Int32, Int) = (-1, 0)
        if r != -1 {
            (r1, width1) = step(pos + width)
        }
        // Go: `newLazyFlag(-1, r)` at the start of text, `i.context(pos)` otherwise. This machine is
        // only ever entered at 0, so the first arm is the only one, but the variable is kept because
        // `step` below needs the *pair* around each position.
        var before: Int32 = -1

        while true {
            if runq.isEmpty {
                // Go also breaks here on an anchored pattern past the start, and on a literal-prefix
                // fast path. `label_replace` compiles `^(?s:...)$`, so `EmptyBeginText` is in the
                // start condition and a restart past position 0 cannot match — but the port does not
                // read `re.cond`, and `matched` plus the loop's own exit cover it.
                if matched { break }
            }
            if !matched {
                matchcap[0] = pos
                var capSnapshot = matchcap
                addThread(&runq, prog.start, pos, &capSnapshot, before, r)
            }

            // The pair straddling the transition out of `pos`.
            stepThreads(
                &runq, &nextq, pos: pos, nextPos: pos + width, c: r, nextBefore: r,
                nextAfter: r1, matchcap: &matchcap, matched: &matched)

            if width == 0 { break }
            before = r
            pos += width
            (r, width) = (r1, width1)
            if r != -1 {
                (r1, width1) = step(pos + width)
            }
            swap(&runq, &nextq)
            nextq.reset()
        }

        return matched ? matchcap : nil
    }

    /// Go: `machine.step`.
    private func stepThreads(
        _ runq: inout CaptureQueue, _ nextq: inout CaptureQueue, pos: Int, nextPos: Int, c: Int32,
        nextBefore: Int32, nextAfter: Int32, matchcap: inout [Int], matched: inout Bool
    ) {
        var j = 0
        while j < runq.dense.count {
            let entry = runq.dense[j]
            guard let caps = entry.caps else {
                j += 1
                continue
            }
            let i = prog.inst[entry.pc]
            var add = false
            switch i.op {
            case .match:
                var t = caps
                t[1] = pos
                matchcap = t
                // **First-match mode: cut every lower-priority thread.** Go's `longest` is false
                // unless the pattern was compiled POSIX, and `label_replace` never is.
                runq.truncate(to: j)
                matched = true
                j += 1
                continue
            case .rune, .rune1, .runeAny, .runeAnyNotNL:
                add = matchesRune(i, c)
            default:
                // `add` never leaves anything but a rune or match instruction in the queue.
                break
            }
            if add {
                var snapshot = caps
                addThread(&nextq, Int(i.out), nextPos, &snapshot, nextBefore, nextAfter)
            }
            j += 1
        }
        runq.clearDense()
    }

    private func matchesRune(_ i: Inst, _ r: Int32) -> Bool {
        guard r >= 0 else { return false }
        let u = UInt32(bitPattern: r)
        switch i.op {
        case .rune1: return i.rune[0] == u
        case .runeAny: return true
        case .runeAnyNotNL: return u != 0x0A
        default: return i.matchRune(u)
        }
    }

    /// Go: `machine.add`, whose `goto Again` is a loop here and whose recursion stays recursion —
    /// the `alt` and `capture` arms both need to come back and continue.
    private func addThread(
        _ q: inout CaptureQueue, _ pc0: Int, _ pos: Int, _ caps: inout [Int], _ before: Int32,
        _ after: Int32
    ) {
        var pc = pc0
        while true {
            if pc == 0 { return }
            if q.contains(pc) { return }
            q.insert(pc)

            let i = prog.inst[pc]
            switch i.op {
            case .fail:
                return
            case .alt, .altMatch:
                // `out` first, so the dense array ends up in priority order.
                addThread(&q, Int(i.out), pos, &caps, before, after)
                pc = Int(i.arg)
                continue
            case .emptyWidth:
                if i.matchEmptyWidth(before, after) {
                    pc = Int(i.out)
                    continue
                }
                return
            case .nop:
                pc = Int(i.out)
                continue
            case .capture:
                let slot = Int(i.arg)
                if slot < caps.count {
                    // Save, recurse, restore — without the restore a capture set on one branch of an
                    // alternation leaks into its sibling.
                    let old = caps[slot]
                    caps[slot] = pos
                    addThread(&q, Int(i.out), pos, &caps, before, after)
                    caps[slot] = old
                    return
                }
                pc = Int(i.out)
                continue
            case .match, .rune, .rune1, .runeAny, .runeAnyNotNL:
                // A thread that consumes input, or the match itself: park it with a copy of the
                // captures as they stand.
                q.attach(pc, caps)
                return
            }
        }
    }
}

/// Go: `queue` — a sparse set whose dense order is the thread priority order, each entry carrying
/// that thread's capture slots.
private struct CaptureQueue {
    struct Entry {
        var pc: Int
        /// `nil` until `add` parks a consuming thread here, matching Go's `d.t = nil` then `d.t = t`.
        var caps: [Int]?
    }

    var dense: [Entry] = []
    private var sparse: [Int]
    private var generation: [Int]
    private var gen = 0
    private let ncap: Int

    init(capacity: Int, ncap: Int) {
        sparse = [Int](repeating: 0, count: capacity)
        generation = [Int](repeating: -1, count: capacity)
        self.ncap = ncap
        dense.reserveCapacity(capacity)
    }

    var isEmpty: Bool { dense.isEmpty }

    func contains(_ pc: Int) -> Bool { generation[pc] == gen }

    mutating func insert(_ pc: Int) {
        generation[pc] = gen
        sparse[pc] = dense.count
        dense.append(Entry(pc: pc, caps: nil))
    }

    mutating func attach(_ pc: Int, _ caps: [Int]) {
        dense[sparse[pc]].caps = caps
    }

    /// Go: `runq.dense = runq.dense[:0]` after a first-match cut — every thread at or below `j`'s
    /// successors is dropped. Go truncates to zero because the loop then ends; the port keeps the
    /// entries up to `j` so the enclosing `while` sees a consistent array, and marks the rest dead.
    mutating func truncate(to j: Int) {
        for k in (j + 1)..<dense.count {
            dense[k].caps = nil
        }
    }

    mutating func clearDense() {
        gen += 1
        dense.removeAll(keepingCapacity: true)
    }

    mutating func reset() {
        gen += 1
        dense.removeAll(keepingCapacity: true)
    }
}

/// Go: `utf8.DecodeRuneInString` — the rune at a byte offset and its width.
///
/// An invalid sequence yields `RuneError` (U+FFFD) with width 1, exactly as Go's decoder does, so a
/// label value that is not valid UTF-8 still advances one byte at a time rather than stalling.
func decodeRune(_ b: [UInt8], _ i: Int) -> (Int32, Int) {
    let c = b[i]
    if c < 0x80 {
        return (Int32(c), 1)
    }
    func cont(_ k: Int) -> Bool { i + k < b.count && b[i + k] & 0xC0 == 0x80 }
    switch c {
    case 0xC2...0xDF:
        if cont(1) {
            return (Int32(UInt32(c & 0x1F) << 6 | UInt32(b[i + 1] & 0x3F)), 2)
        }
    case 0xE0...0xEF:
        if cont(1) && cont(2) {
            let r =
                UInt32(c & 0x0F) << 12 | UInt32(b[i + 1] & 0x3F) << 6 | UInt32(b[i + 2] & 0x3F)
            // Overlongs and surrogates are `RuneError` in Go, not the value they encode.
            if r >= 0x800 && !(0xD800...0xDFFF).contains(r) {
                return (Int32(r), 3)
            }
        }
    case 0xF0...0xF4:
        if cont(1) && cont(2) && cont(3) {
            let r =
                UInt32(c & 0x07) << 18 | UInt32(b[i + 1] & 0x3F) << 12
                | UInt32(b[i + 2] & 0x3F) << 6 | UInt32(b[i + 3] & 0x3F)
            if r >= 0x1_0000 && r <= 0x10_FFFF {
                return (Int32(r), 4)
            }
        }
    default:
        break
    }
    // Go: `RuneError, 1`.
    return (0xFFFD, 1)
}

/// Go: `Regexp.expand` — the `$1` / `${name}` template language, which is **not** the shell's and not
/// `sed`'s.
///
/// The rules that catch people out, all of them upstream's:
///
///   * a `$` not followed by a name expands to **nothing**, and a trailing `$` likewise. `$$` is not
///     an escape for a literal dollar — there is no escape;
///   * `$1x` reads the longest possible name, so it means group `1x` (which does not exist, so
///     nothing) rather than group 1 followed by `x`. `${1}x` is how that is written;
///   * a name is letters, digits and underscore. `$1a` is one name; `$1-` is the name `1` then `-`;
///   * an all-digit name is a group NUMBER, otherwise it is a group name; either way an unknown
///     group expands to nothing rather than erroring.
public func regexExpand(
    _ dst: [UInt8], _ template: [UInt8], _ src: [UInt8], _ match: [Int],
    _ groupNames: [String: Int]
) -> [UInt8] {
    var out = dst
    var t = template
    while !t.isEmpty {
        guard let i = t.firstIndex(of: UInt8(ascii: "$")) else { break }
        out.append(contentsOf: t[t.startIndex..<i])
        t = Array(t[(i + 1)...])
        if t.first == UInt8(ascii: "$") {
            // Go: "Treat $$ as $." — the ONE special case, and it is in `extract`'s caller rather
            // than a general escape.
            out.append(UInt8(ascii: "$"))
            t = Array(t.dropFirst())
            continue
        }
        guard let (name, num, rest) = extractGroupName(t) else {
            // Malformed: Go writes the `$` back out and moves on.
            out.append(UInt8(ascii: "$"))
            continue
        }
        t = rest
        // Go tests `2*i+1 < len(match) && match[2*i] >= 0` — the END offset is not checked, because a
        // participating group always has both or neither.
        let index = num >= 0 ? num : (groupNames[name] ?? -1)
        if index >= 0, 2 * index + 1 < match.count, match[2 * index] >= 0 {
            out.append(contentsOf: src[match[2 * index]..<match[2 * index + 1]])
        }
    }
    out.append(contentsOf: t)
    return out
}

/// Go: `extract` — the name after a `$`, plus its numeric value when it is all digits.
///
/// Returns `nil` when the reference is malformed, which upstream signals with `ok == false` and which
/// makes the caller emit the `$` literally.
///
/// **The name characters are `unicode.IsLetter || unicode.IsDigit || '_'` over RUNES**, not ASCII —
/// `${café}` is a legal group name upstream. So this decodes runes and consults the same `L` and `N`
/// category tables the parser uses for `\pL`, rather than doing a byte-range test that would agree on
/// ASCII and silently reject the rest.
///
/// Two more details from the source: a **leading zero** disqualifies a multi-digit name from being a
/// group *number* (`$01` is a name, not group 1), and the overflow guard is `num >= 1e8` tested
/// *before* each accumulation.
func extractGroupName(_ str: [UInt8]) -> (name: String, num: Int, rest: [UInt8])? {
    if str.isEmpty { return nil }
    var s = str
    var brace = false
    if s[0] == UInt8(ascii: "{") {
        brace = true
        s = Array(s.dropFirst())
    }
    var i = 0
    while i < s.count {
        let (r, size) = decodeRune(s, i)
        if !isUnicodeLetterOrDigit(r) && r != Int32(UInt8(ascii: "_")) {
            break
        }
        i += size
    }
    if i == 0 {
        // Go: "empty name is not okay".
        return nil
    }
    let nameBytes = Array(s[0..<i])
    if brace {
        if i >= s.count || s[i] != UInt8(ascii: "}") {
            // Go: "missing closing brace".
            return nil
        }
        i += 1
    }

    // Go: parse the number, bailing to -1 on a non-digit or at 1e8.
    var num = 0
    for c in nameBytes {
        if c < UInt8(ascii: "0") || c > UInt8(ascii: "9") || num >= 100_000_000 {
            num = -1
            break
        }
        num = num * 10 + Int(c - UInt8(ascii: "0"))
    }
    // Go: "Disallow leading zeros."
    if nameBytes[0] == UInt8(ascii: "0") && nameBytes.count > 1 {
        num = -1
    }

    let name = String(decoding: nameBytes, as: UTF8.self)
    return (name, num, Array(s[i...]))
}

/// Go: `unicode.IsLetter(r) || unicode.IsDigit(r)`.
///
/// `IsDigit` is category **Nd** specifically, not all of `N` — `unicode.IsDigit` is documented as "the
/// decimal digit property", so Roman numerals (`Nl`) and fractions (`No`) are not digits. The same
/// generated tables the parser uses for `\p{L}` and `\p{Nd}` answer both.
func isUnicodeLetterOrDigit(_ r: Int32) -> Bool {
    guard r >= 0 else { return false }
    let u = UInt32(bitPattern: r)
    return inUnicodeTable(u, UnicodeTables.categories["L"] ?? [])
        || inUnicodeTable(u, UnicodeTables.categories["Nd"] ?? [])
}

/// The generated tables are `(lo, hi, stride)` triples, so membership is a range test plus a stride
/// check — a scalar inside `lo...hi` is only in the set when it sits on the stride.
func inUnicodeTable(_ r: UInt32, _ ranges: [(lo: UInt32, hi: UInt32, stride: UInt32)]) -> Bool {
    var lo = 0
    var hi = ranges.count
    while lo < hi {
        let m = (lo + hi) / 2
        let range = ranges[m]
        if r < range.lo {
            hi = m
        } else if r > range.hi {
            lo = m + 1
        } else {
            return range.stride == 1 || (r - range.lo) % range.stride == 0
        }
    }
    return false
}

/// A parsed, simplified and compiled pattern, plus the capture metadata `label_replace` needs.
///
/// Go's `Regexp` carries `numSubexp` and `subexpNames` alongside the program because `expand` needs
/// them to resolve `$name`. `PromRegex` had no such wrapper: `FastRegexMatcher` is a matcher-shaped
/// API and the boolean VM never asked which group was which.
public struct CompiledRegex: Sendable {
    public let prog: RegexProgram
    /// Go: `Regexp.NumSubexp` — the number of capturing groups, not counting the whole match.
    public let numSubexp: Int
    /// Go: `Regexp.SubexpNames` — index 0 is the whole match and its entry is the **empty string**,
    /// not a missing value, and an unnamed group's entry is likewise empty. `[String]` rather than
    /// `[String?]`: modelling index 0 as "no name" is the more expressive choice and it is the wrong
    /// one, which 62 of 66 corpus cases said in unison.
    public let subexpNames: [String]
    private let names: [String: Int]
    private let machine: RegexCaptureMachine

    /// Go: `regexp.Compile("^(?s:" + pattern + ")$")`, which is exactly and only how
    /// `evalLabelReplace` compiles. The wrapper is a NON-capturing group, so the caller's group
    /// numbering is unchanged.
    public init(anchoredForLabelReplace pattern: String) throws {
        try self.init(pattern: "^(?s:" + pattern + ")$")
    }

    public init(pattern: String) throws {
        let re = try parseRegex(pattern)
        let simplified = re.simplify()
        self.prog = compileRegex(simplified)
        var maxCap = 0
        var byName: [String: Int] = [:]
        var nameByIndex: [Int: String] = [:]
        Self.walk(re) { node in
            guard node.op == .capture else { return }
            maxCap = Swift.max(maxCap, node.cap)
            let n = node.name
            if !n.isEmpty {
                byName[n] = node.cap
                nameByIndex[node.cap] = n
            }
        }
        self.numSubexp = maxCap
        self.names = byName
        self.subexpNames = (0...maxCap).map { nameByIndex[$0] ?? "" }
        self.machine = RegexCaptureMachine(prog)
    }

    /// Walks the ORIGINAL parse tree rather than the simplified one: `simplify` can rewrite a
    /// repetition into a chain of copies, which would count a capture group more than once. The
    /// numbering is assigned by the parser, so the parse tree is the authority.
    private static func walk(_ re: Regexp, _ f: (Regexp) -> Void) {
        f(re)
        for sub in re.sub {
            walk(sub, f)
        }
    }

    public func findSubmatchIndex(_ bytes: [UInt8]) -> [Int]? {
        machine.findSubmatchIndex(bytes)
    }

    /// Go: `Regexp.ExpandString`.
    public func expand(_ dst: [UInt8], _ template: [UInt8], _ src: [UInt8], _ match: [Int])
        -> [UInt8]
    {
        regexExpand(dst, template, src, match, names)
    }
}

/// Go: `regexp.MatchString` — an **unanchored** search, which is what `promqltest`'s
/// `expect fail regex:` and `expect … regex:` lines mean.
///
/// The capture VM gives this for free: `findSubmatchIndex` re-seeds the start state at every position
/// while it has not matched, which is exactly an unanchored search. And this is the caller that makes
/// the first-match cut load-bearing — with an unanchored pattern a lower-priority thread really can
/// match further right, which is the case quirk 115 says the cut exists for.
public func regexMatchesUnanchored(_ pattern: String, _ subject: String) throws -> Bool {
    let re = try CompiledRegex(pattern: pattern)
    return re.findSubmatchIndex(Array(subject.utf8)) != nil
}
