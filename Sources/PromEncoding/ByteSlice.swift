//===----------------------------------------------------------------------===//
// Ported from tsdb/encoding/encoding.go @ v3.13.2
//
// ADR-8: `ByteSlice` is a concrete struct rather than a protocol. Go declares
// three structurally identical `ByteSlice` interfaces (here, tsdb/index/index.go
// and tsdb/chunks/chunks.go) whose `Range()` is zero-cost; index and postings
// reads are TSDB's hottest path, so an existential would put a retain/release
// and a witness-table dispatch on every read.
//===----------------------------------------------------------------------===//

/// A non-owning view over bytes. Lifetime belongs to the `ByteSliceOwner`.
///
/// `@unchecked Sendable` is justified structurally: every `ByteSlice` derives
/// from an owner that the reader retains, so the memory outlives the view.
public struct ByteSlice: @unchecked Sendable {

    @usableFromInline internal let base: UnsafeRawPointer
    /// Go: `ByteSlice.Len()`.
    public let count: Int

    @inlinable
    public init(base: UnsafeRawPointer, count: Int) {
        self.base = base
        self.count = count
    }

    @inlinable
    public init(_ buffer: UnsafeRawBufferPointer) {
        self.base = buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!
        self.count = buffer.count
    }

    @inlinable public var isEmpty: Bool { count == 0 }

    @inlinable
    public subscript(i: Int) -> UInt8 {
        base.load(fromByteOffset: i, as: UInt8.self)
    }

    /// Go: `ByteSlice.Range(start, end)`. No copy.
    @inlinable
    public func range(_ start: Int, _ end: Int) -> ByteSlice {
        ByteSlice(base: base + start, count: end - start)
    }

    // Loops rather than chained shift-or expressions: long chains of shifted
    // UInt64s exceed the Swift 6.1 type checker's budget. The optimiser unrolls.
    @inlinable
    public func loadBE32(at off: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v = (v << 8) | UInt32(self[off + k]) }
        return v
    }

    @inlinable
    public func loadBE64(at off: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(self[off + k]) }
        return v
    }

    @inlinable
    public var rawBuffer: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: base, count: count)
    }

    /// Scoped access for hot inner loops.
    ///
    /// ADR-8 note: a `var span: RawSpan` accessor does not compile — "a method
    /// cannot return a ~Escapable result" without lifetime annotations, and this
    /// type is escapable and stored inside `Decbuf`. Revisit when `~Escapable`
    /// stored properties and `@lifetime` are available; until then this closure
    /// form gives the same zero-copy access.
    @inlinable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(rawBuffer)
    }

    public func copyToArray() -> [UInt8] { Array(rawBuffer) }
}

/// Anything that keeps a `ByteSlice`'s memory alive: a mapped file, a retained
/// `[UInt8]`, a NIO `ByteBuffer`.
public protocol ByteSliceOwner: AnyObject, Sendable {
    var bytes: ByteSlice { get }
}

/// An owner backed by an owned allocation — useful for tests and small in-memory
/// reads. Copies on init so the pointer is stable and legitimately escapable
/// (escaping the pointer from `Array.withUnsafeBytes` would be undefined).
public final class ArrayByteSliceOwner: ByteSliceOwner, @unchecked Sendable {
    private let allocation: UnsafeMutableRawBufferPointer
    public let bytes: ByteSlice

    public init(_ source: [UInt8]) {
        let alloc = UnsafeMutableRawBufferPointer.allocate(
            byteCount: max(source.count, 1), alignment: 8)
        source.withUnsafeBytes { alloc.copyMemory(from: $0) }
        allocation = alloc
        bytes = ByteSlice(base: UnsafeRawPointer(alloc.baseAddress!), count: source.count)
    }

    deinit { allocation.deallocate() }
}

/// Go: `encoding.ErrInvalidSize` / `ErrInvalidChecksum`.
public enum EncodingError: Error, Equatable, CustomStringConvertible {
    case invalidSize
    case invalidChecksum
    case invalidUvarint(Int)

    public var description: String {
        switch self {
        case .invalidSize: return "invalid size"
        case .invalidChecksum: return "invalid checksum"
        case .invalidUvarint(let n): return "invalid uvarint \(n)"
        }
    }
}
