//===----------------------------------------------------------------------===//
// NOT a port. This is the filesystem seam ADR-15 decided, standing in for the parts of `os`,
// `fileutil` and `mmap` that the TSDB reaches for: `chunks.Writer` holds a directory handle and one
// `*os.File` per segment, `index.Writer` wraps a `fileutil.BufWriter`, and both readers mmap what they
// produced.
//
// **Read ADR-15 before changing this.** The shape is a decision, not a convenience: the port depends on
// the protocol, corpora drive `InMemoryFS`, and `RealFS` is pinned separately and thinly. That is the same
// seam `Queryable` provides for storage, and it exists for the same reason — `swift test` is hermetic by
// contract (CLAUDE.md), so a slice that needed a scratch directory would be a slice that fails differently
// on CI.
//
// ## Three things this deliberately does NOT have
//
//   * **No `mmap`.** `ByteSlice` is already an abstraction upstream, so a reader is handed one over a
//     fully-read file. That is a real behavioural difference — upstream reads a 512 MiB index without
//     resident memory and this cannot — and it is a documented exception rather than a hidden one.
//   * **No pre-allocation.** `cutSegmentFile`'s `allocSize` affects fragmentation and nothing observable.
//   * **No durability.** `sync` is a no-op with a comment, so the call sites keep upstream's shape
//     (PORTING.md §4) and a later durability slice has somewhere to put the real thing. Crash-consistency
//     is untestable in this harness and unobservable in a corpus.
//
// ## Append-only, deliberately
//
// The protocol has `append` and `truncate` but no seek-and-write, because the TSDB never rewrites a byte
// it has already flushed — except for `index.Writer.writeAt`, which patches a length prefix once the
// section's size is known. That one case is `writeAt`, and it is the only random-access write here; adding
// a general seek would invite call sites upstream does not have.
//===----------------------------------------------------------------------===//

public import PromEncoding

internal import Foundation

/// The errors a filesystem surfaces. Deliberately few: the TSDB distinguishes "not there" from "broken"
/// and little else.
public enum FSError: Error, CustomStringConvertible, Equatable, Sendable {
    case notFound(String)
    case alreadyExists(String)
    case notADirectory(String)
    case isADirectory(String)
    case outOfBounds(path: String, offset: Int, length: Int, size: Int)
    case closed(String)

    public var description: String {
        switch self {
        case .notFound(let p): return "no such file or directory: \(p)"
        case .alreadyExists(let p): return "file exists: \(p)"
        case .notADirectory(let p): return "not a directory: \(p)"
        case .isADirectory(let p): return "is a directory: \(p)"
        case .outOfBounds(let p, let o, let l, let s):
            return "read out of bounds: \(p) [\(o), \(o + l)) of \(s) bytes"
        case .closed(let p): return "file already closed: \(p)"
        }
    }
}

/// A handle open for appending. Go's `*os.File` plus `fileutil.BufWriter`.
public protocol FSWriteHandle: AnyObject {
    /// Bytes written so far. Go: `FileWriter.Pos()`.
    var position: Int { get }
    /// Go: `Write(bufs ...[]byte)` — one call per buffer, appended in order.
    func append(_ bytes: [UInt8]) throws
    /// Go: `WriteAt(buf, pos)` — the ONLY random-access write, used to patch a length prefix once a
    /// section's size is known. See the file header.
    func write(_ bytes: [UInt8], at position: Int) throws
    /// Go: `AddPadding(size)` — zero bytes until the position is a multiple of `size`.
    func addPadding(to alignment: Int) throws
    /// Go: `Flush()` then `Sync()`. Flushing is real; syncing is not — see the file header.
    func flush() throws
    func sync() throws
    func close() throws
}

/// A handle open for reading, exposing the whole file as a `ByteSlice`.
public protocol FSReadHandle: AnyObject {
    var size: Int { get }
    /// The file's contents. **Fully resident**, because ADR-15 declines `mmap`.
    func byteSlice<R>(_ body: (ByteSlice) throws -> R) throws -> R
    /// Go: `ByteSlice.Range(start, end)`, for callers that want bytes rather than a slice.
    func read(offset: Int, length: Int) throws -> [UInt8]
    func close() throws
}

/// The filesystem the TSDB writes to and reads from.
public protocol PromFS: Sendable {
    func createDirectory(_ path: String) throws
    /// Go: `os.Open(dir)` then `Sync()` on the handle. Directories are opened only to be synced, which is
    /// a no-op here, so this returns nothing and exists for the call-site shape.
    func syncDirectory(_ path: String) throws
    /// Go: `fileutil.ReadDir` — names only, sorted, no `.` or `..`.
    func list(_ path: String) throws -> [String]
    func exists(_ path: String) -> Bool
    func remove(_ path: String) throws

    /// Go: `os.OpenFile(name, O_WRONLY|O_CREATE|O_TRUNC, 0o666)`.
    func createFile(_ path: String) throws -> any FSWriteHandle
    func openForReading(_ path: String) throws -> any FSReadHandle
}

// MARK: - The in-memory implementation

/// The filesystem corpora run against. Every byte lives in a dictionary, so a test needs no scratch
/// directory and two runs cannot interfere.
public final class InMemoryFS: PromFS, @unchecked Sendable {
    /// Path -> contents. Directories are entries with `nil` contents, which keeps `exists` and `list`
    /// answerable without a second structure.
    ///
    /// **Every write to this dictionary uses `updateValue(nil, forKey:)`, never `files[k] = nil`.** For a
    /// `Dictionary` whose Value is itself Optional, subscript-assigning `nil` REMOVES the key rather than
    /// storing a nil value — so `files[dir] = nil` silently created nothing and every directory appeared
    /// not to exist. Seven of nine tests failed with "no such file or directory" before this was spotted.
    private var files: [String: [UInt8]?] = [:]
    private let lock = NSLock()

    public init() {
        // The root, which `parent("f")` resolves to.
        files.updateValue(nil, forKey: "")
    }

    /// Normalises a path the way the TSDB's own joins produce them: no trailing slash, no `.` segments.
    private static func normalise(_ path: String) -> String {
        var parts: [String] = []
        for c in path.split(separator: "/") where c != "." && !c.isEmpty {
            parts.append(String(c))
        }
        return parts.joined(separator: "/")
    }

    private static func parent(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    public func createDirectory(_ path: String) throws {
        let p = Self.normalise(path)
        lock.lock()
        defer { lock.unlock() }
        // Go's `os.MkdirAll` creates intermediate directories and does not error when they exist.
        var acc: [String] = []
        for c in p.split(separator: "/") {
            acc.append(String(c))
            let dir = acc.joined(separator: "/")
            if let existing = files[dir], existing != nil {
                throw FSError.notADirectory(dir)
            }
            files.updateValue(nil, forKey: dir)
        }
    }

    /// A no-op, and ADR-15 says why.
    public func syncDirectory(_ path: String) throws {
        let p = Self.normalise(path)
        lock.lock()
        defer { lock.unlock() }
        guard let e = files[p], e == nil else {
            throw FSError.notFound(p)
        }
    }

    public func list(_ path: String) throws -> [String] {
        let p = Self.normalise(path)
        lock.lock()
        defer { lock.unlock() }
        guard let e = files[p], e == nil else {
            throw FSError.notFound(p)
        }
        var names = Set<String>()
        let prefix = p.isEmpty ? "" : p + "/"
        for key in files.keys where key != p && key.hasPrefix(prefix) {
            let rest = String(key.dropFirst(prefix.count))
            // Direct children only.
            if let slash = rest.firstIndex(of: "/") {
                names.insert(String(rest[rest.startIndex..<slash]))
            } else if !rest.isEmpty {
                names.insert(rest)
            }
        }
        // Go's `fileutil.ReadDir` returns names sorted.
        return names.sorted()
    }

    public func exists(_ path: String) -> Bool {
        let p = Self.normalise(path)
        lock.lock()
        defer { lock.unlock() }
        return files.index(forKey: p) != nil
    }

    public func remove(_ path: String) throws {
        let p = Self.normalise(path)
        lock.lock()
        defer { lock.unlock() }
        guard files.index(forKey: p) != nil else {
            throw FSError.notFound(p)
        }
        // Removing a directory removes its subtree, like `os.RemoveAll`.
        let prefix = p + "/"
        for key in files.keys where key == p || key.hasPrefix(prefix) {
            files.removeValue(forKey: key)
        }
    }

    public func createFile(_ path: String) throws -> any FSWriteHandle {
        let p = Self.normalise(path)
        lock.lock()
        let parent = Self.parent(p)
        guard let pe = files[parent], pe == nil else {
            lock.unlock()
            throw FSError.notFound(parent)
        }
        // O_TRUNC: an existing file is emptied rather than appended to.
        files.updateValue([], forKey: p)
        lock.unlock()
        return InMemoryWriteHandle(fs: self, path: p)
    }

    public func openForReading(_ path: String) throws -> any FSReadHandle {
        let p = Self.normalise(path)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = files[p] else {
            throw FSError.notFound(p)
        }
        guard let contents = entry else {
            throw FSError.isADirectory(p)
        }
        return InMemoryReadHandle(path: p, contents: contents)
    }

    // Used by the write handle.
    fileprivate func mutate(_ path: String, _ body: (inout [UInt8]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var c = (files[path] ?? []) ?? []
        body(&c)
        files.updateValue(c, forKey: path)
    }

    fileprivate func size(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (files[path] ?? [])?.count ?? 0
    }
}

private final class InMemoryWriteHandle: FSWriteHandle {
    private let fs: InMemoryFS
    private let path: String
    private var isClosed = false
    private(set) var position: Int = 0

    init(fs: InMemoryFS, path: String) {
        self.fs = fs
        self.path = path
    }

    func append(_ bytes: [UInt8]) throws {
        if isClosed { throw FSError.closed(path) }
        fs.mutate(path) { $0.append(contentsOf: bytes) }
        position += bytes.count
    }

    func write(_ bytes: [UInt8], at position: Int) throws {
        if isClosed { throw FSError.closed(path) }
        fs.mutate(path) { contents in
            // Go's `WriteAt` past the end grows the file with zeros; the TSDB only ever patches a prefix
            // it has already written, so this is defensive rather than exercised.
            if position + bytes.count > contents.count {
                contents.append(
                    contentsOf: [UInt8](repeating: 0, count: position + bytes.count - contents.count))
            }
            contents.replaceSubrange(position..<(position + bytes.count), with: bytes)
        }
        // `WriteAt` does NOT move the append position — Go's file offset is separate from `Pos()`.
    }

    func addPadding(to alignment: Int) throws {
        let remainder = position % alignment
        if remainder == 0 { return }
        try append([UInt8](repeating: 0, count: alignment - remainder))
    }

    /// Real: the in-memory store is written through on every append, so there is nothing buffered.
    func flush() throws {
        if isClosed { throw FSError.closed(path) }
    }

    /// A no-op. ADR-15: durability is untestable here and unobservable in a corpus.
    func sync() throws {
        if isClosed { throw FSError.closed(path) }
    }

    func close() throws {
        isClosed = true
    }
}

private final class InMemoryReadHandle: FSReadHandle {
    private let path: String
    private let contents: [UInt8]
    private var isClosed = false

    init(path: String, contents: [UInt8]) {
        self.path = path
        self.contents = contents
    }

    var size: Int { contents.count }

    func byteSlice<R>(_ body: (ByteSlice) throws -> R) throws -> R {
        if isClosed { throw FSError.closed(path) }
        return try contents.withUnsafeBytes { try body(ByteSlice($0)) }
    }

    func read(offset: Int, length: Int) throws -> [UInt8] {
        if isClosed { throw FSError.closed(path) }
        guard offset >= 0, length >= 0, offset + length <= contents.count else {
            throw FSError.outOfBounds(
                path: path, offset: offset, length: length, size: contents.count)
        }
        return Array(contents[offset..<(offset + length)])
    }

    func close() throws {
        isClosed = true
    }
}
