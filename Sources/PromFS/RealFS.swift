//===----------------------------------------------------------------------===//
// NOT a port. The `FileManager`-backed half of ADR-15's seam, for reading and writing directories a real
// Prometheus produced.
//
// **This file is deliberately thin and deliberately barely tested.** Every corpus in the project drives
// `InMemoryFS`, so the byte-level behaviour of the writers and readers is pinned against Go without this
// existing at all. What is left for `RealFS` to get right is the mapping onto the filesystem — which is
// exactly the part a differential corpus cannot check and a unit test can, so its tests are a handful of
// round trips in a temporary directory rather than an attempt at coverage.
//
// ## Reads are eager, per ADR-15
//
// `openForReading` reads the whole file. That is the documented exception ADR-15 records: upstream mmaps a
// 512 MiB index and touches only what it needs; this holds all of it. Revisit on a benchmark, not a hunch —
// and note the divergence is *behavioural* as well as spatial, because an mmapped reader can observe an
// appender's writes and this cannot (the same concurrency question quirk 120 raised).
//
// ## Appends go through one `FileHandle`, and `write(at:)` seeks back
//
// `FSWriteHandle.append` and `write(_:at:)` share a handle: the append position is tracked explicitly
// rather than read from the handle, because `write(at:)` must not disturb it (which is the behaviour
// `PromFSTests` pins and which `index.Writer` depends on when it patches a length prefix).
//===----------------------------------------------------------------------===//

public import PromEncoding

internal import Foundation

/// ADR-15's real filesystem.
public struct RealFS: PromFS {
    public init() {}

    public func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    }

    /// A no-op, as ADR-15 says. Upstream opens the directory and `Sync`s it so a rename is durable; this
    /// project has no crash-consistency test that could observe the difference, so the call is kept for the
    /// call-site shape and does nothing.
    public func syncDirectory(_ path: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw FSError.notFound(path)
        }
    }

    /// Go: `fileutil.ReadDir` — names only, sorted.
    public func list(_ path: String) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        } catch {
            throw FSError.notFound(path)
        }
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func remove(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw FSError.notFound(path)
        }
        try FileManager.default.removeItem(atPath: path)
    }

    /// Go: `os.OpenFile(name, O_WRONLY|O_CREATE|O_TRUNC, 0o666)`.
    public func createFile(_ path: String) throws -> any FSWriteHandle {
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty && !FileManager.default.fileExists(atPath: parent) {
            throw FSError.notFound(parent)
        }
        // Truncate by replacing.
        FileManager.default.createFile(atPath: path, contents: Data())
        guard let h = FileHandle(forWritingAtPath: path) else {
            throw FSError.notFound(path)
        }
        return RealWriteHandle(path: path, handle: h)
    }

    public func openForReading(_ path: String) throws -> any FSReadHandle {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw FSError.notFound(path)
        }
        if isDir.boolValue {
            throw FSError.isADirectory(path)
        }
        // EAGER, per ADR-15.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return RealReadHandle(path: path, contents: [UInt8](data))
    }
}

private final class RealWriteHandle: FSWriteHandle {
    private let path: String
    private let handle: FileHandle
    private var isClosed = false
    /// Tracked explicitly, not read from the handle: `write(at:)` seeks and must not disturb it.
    private(set) var position: Int = 0

    init(path: String, handle: FileHandle) {
        self.path = path
        self.handle = handle
    }

    func append(_ bytes: [UInt8]) throws {
        if isClosed { throw FSError.closed(path) }
        try handle.seek(toOffset: UInt64(position))
        try handle.write(contentsOf: Data(bytes))
        position += bytes.count
    }

    func write(_ bytes: [UInt8], at position: Int) throws {
        if isClosed { throw FSError.closed(path) }
        try handle.seek(toOffset: UInt64(position))
        try handle.write(contentsOf: Data(bytes))
        // `self.position` is deliberately unchanged — see the type's note.
    }

    func addPadding(to alignment: Int) throws {
        let remainder = position % alignment
        if remainder == 0 { return }
        try append([UInt8](repeating: 0, count: alignment - remainder))
    }

    func flush() throws {
        if isClosed { throw FSError.closed(path) }
        // `FileHandle.write` is unbuffered, so there is nothing to flush.
    }

    /// A no-op, per ADR-15. `handle.synchronize()` would be the real thing and is left for a durability
    /// slice with a test that can observe it.
    func sync() throws {
        if isClosed { throw FSError.closed(path) }
    }

    func close() throws {
        if isClosed { return }
        isClosed = true
        try handle.close()
    }
}

private final class RealReadHandle: FSReadHandle {
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
