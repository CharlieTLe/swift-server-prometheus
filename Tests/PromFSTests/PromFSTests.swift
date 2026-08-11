//===----------------------------------------------------------------------===//
// `PromFS` is NOT a port, so it has no differential corpus — there is no Go function to compare against.
// These are hand-written behavioural tests, which CLAUDE.md's "correctness is defined by differential
// testing" rule tolerates precisely because the subject is the port's own seam rather than upstream
// behaviour. What upstream behaviour there is gets pinned where it belongs: the index and chunk writers
// that will run on top of this are compared byte-for-byte against Go's, and a bug in `InMemoryFS` shows
// up there as wrong bytes.
//
// So the job here is narrow: prove the seam does what ADR-15 says, including the parts that are
// deliberately no-ops, so a later reader does not mistake them for oversights.
//===----------------------------------------------------------------------===//

import PromEncoding
import PromFS
import Testing

@Suite("PromFS: the filesystem seam ADR-15 decided")
struct PromFSTests {

    @Test("a written file reads back byte for byte")
    func roundTrip() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("a/b")
        let w = try fs.createFile("a/b/chunks")
        try w.append([1, 2, 3])
        try w.append([4, 5])
        #expect(w.position == 5)
        try w.flush()
        try w.close()

        let r = try fs.openForReading("a/b/chunks")
        #expect(r.size == 5)
        #expect(try r.read(offset: 0, length: 5) == [1, 2, 3, 4, 5])
        #expect(try r.read(offset: 1, length: 3) == [2, 3, 4])
        let sum = try r.byteSlice { bs -> Int in
            #expect(bs.count == 5)
            return Int(bs.range(0, 5).loadBE32(at: 0))
        }
        #expect(sum == 0x0102_0304)
        try r.close()
    }

    /// `write(_:at:)` is the only random-access write, and it must NOT move the append position — Go's
    /// file offset and `FileWriter.Pos()` are separate, and `index.Writer` relies on that when it patches
    /// a length prefix mid-file and then keeps appending.
    @Test("write(at:) patches in place without moving the append position")
    func writeAtDoesNotMovePosition() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("d")
        let w = try fs.createFile("d/index")
        try w.append([0, 0, 0, 0])  // A length prefix to patch later.
        try w.append([9, 9, 9])
        let posBefore = w.position
        try w.write([0, 0, 0, 3], at: 0)
        #expect(w.position == posBefore, "write(at:) must not move the append cursor")
        try w.append([7])
        try w.close()

        let r = try fs.openForReading("d/index")
        #expect(try r.read(offset: 0, length: 8) == [0, 0, 0, 3, 9, 9, 9, 7])
    }

    /// `addPadding` aligns the position, and does nothing when it is already aligned — `chunks.Writer`
    /// and `index.Writer` both depend on the second half, because they call it unconditionally.
    @Test("addPadding aligns and is a no-op when already aligned")
    func padding() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("d")
        let w = try fs.createFile("d/f")
        try w.append([1, 2, 3])
        try w.addPadding(to: 16)
        #expect(w.position == 16)
        try w.addPadding(to: 16)
        #expect(w.position == 16, "already aligned, so nothing more is written")
        try w.close()
        let r = try fs.openForReading("d/f")
        #expect(try r.read(offset: 3, length: 13) == [UInt8](repeating: 0, count: 13))
    }

    /// Creating a file truncates an existing one — `O_TRUNC`, which is what `os.OpenFile` is given.
    @Test("createFile truncates an existing file")
    func createTruncates() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("d")
        let w1 = try fs.createFile("d/f")
        try w1.append([1, 2, 3, 4])
        try w1.close()
        let w2 = try fs.createFile("d/f")
        try w2.append([9])
        try w2.close()
        let r = try fs.openForReading("d/f")
        #expect(r.size == 1)
        #expect(try r.read(offset: 0, length: 1) == [9])
    }

    /// `list` returns DIRECT children only, sorted — `fileutil.ReadDir`'s contract, which the chunk
    /// reader relies on to enumerate segments in order.
    @Test("list returns sorted direct children only")
    func listing() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("d/sub")
        for name in ["000003", "000001", "000002"] {
            let w = try fs.createFile("d/\(name)")
            try w.close()
        }
        let w = try fs.createFile("d/sub/nested")
        try w.close()

        #expect(try fs.list("d") == ["000001", "000002", "000003", "sub"])
        #expect(try fs.list("d/sub") == ["nested"])
    }

    @Test("the error cases each report their own path")
    func errors() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("d")
        #expect(throws: FSError.notFound("nope")) { _ = try fs.openForReading("nope") }
        #expect(throws: FSError.isADirectory("d")) { _ = try fs.openForReading("d") }
        #expect(throws: FSError.notFound("missing")) { _ = try fs.list("missing") }
        #expect(throws: FSError.notFound("gone")) { try fs.remove("gone") }
        // A file under a directory that does not exist.
        #expect(throws: FSError.notFound("absent")) { _ = try fs.createFile("absent/f") }

        let w = try fs.createFile("d/f")
        try w.append([1, 2, 3])
        try w.close()
        let r = try fs.openForReading("d/f")
        #expect(throws: FSError.outOfBounds(path: "d/f", offset: 1, length: 5, size: 3)) {
            _ = try r.read(offset: 1, length: 5)
        }
        try r.close()
        #expect(throws: FSError.closed("d/f")) { _ = try r.read(offset: 0, length: 1) }
    }

    /// `remove` on a directory takes the subtree, like `os.RemoveAll`.
    @Test("remove takes a directory's subtree")
    func removeSubtree() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("d/sub")
        let w = try fs.createFile("d/sub/f")
        try w.close()
        #expect(fs.exists("d/sub/f"))
        try fs.remove("d")
        #expect(!fs.exists("d"))
        #expect(!fs.exists("d/sub"))
        #expect(!fs.exists("d/sub/f"))
    }

    /// **The deliberate no-ops.** ADR-15 declines durability, so `sync` and `syncDirectory` succeed
    /// without doing anything. Asserting that is not a tautology: it stops a later reader from
    /// "fixing" them, and it fails loudly if someone makes them throw.
    @Test("sync and syncDirectory are no-ops that succeed")
    func syncIsANoOp() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("d")
        let w = try fs.createFile("d/f")
        try w.append([1])
        try w.sync()
        try fs.syncDirectory("d")
        try w.close()
        // Still readable, and no side effect to observe — which is the point.
        let r = try fs.openForReading("d/f")
        #expect(r.size == 1)
    }

    /// A reader sees the file as of `openForReading`, because ADR-15 declines mmap and reads the contents
    /// eagerly. That is a real divergence from upstream, where a reader mmaps and an appender's writes can
    /// become visible — and it is exactly the concurrency question quirk 120 raised for chunks. Asserting
    /// the snapshot semantics keeps the divergence documented rather than incidental.
    @Test("a reader snapshots the file at open, unlike an mmap")
    func readerSnapshots() throws {
        let fs = InMemoryFS()
        try fs.createDirectory("d")
        let w = try fs.createFile("d/f")
        try w.append([1, 2])
        let r = try fs.openForReading("d/f")
        try w.append([3, 4])
        #expect(r.size == 2, "the reader does not see writes made after it opened")
        let r2 = try fs.openForReading("d/f")
        #expect(r2.size == 4)
    }
}
