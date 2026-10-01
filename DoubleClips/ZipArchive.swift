import Foundation
import Compression

// MARK: - Minimal streaming ZIP reader
//
// Foundation has no unzip API, and a package dependency would have to be added by hand in
// Xcode, so this reads ZIPs directly with Apple's Compression framework (COMPRESSION_ZLIB is
// raw DEFLATE, which is exactly what ZIP method 8 stores).
//
// Why it works the way it does:
//   - Entries are located through the CENTRAL DIRECTORY, never by scanning local headers.
//     Java's ZipOutputStream (Android and the desktop app) writes sizes and CRC *after* the data
//     (flag bit 3), so a local header says 0 — only the central directory is authoritative.
//   - Every entry is streamed in 256 KB chunks: a multi-GB video never sits in memory.
//   - Zip64 is supported (projects with big media can pass 4 GB).
//   - CRC32 and size are verified, so a truncated/corrupt download fails loudly instead of
//     producing a project with half a video.

enum ZipError: LocalizedError {
    case notAZip
    case truncated
    case encrypted(String)
    case unsupportedMethod(String, UInt16)
    case corrupt(String)
    case unsafePath(String)
    case cancelled
    case notEnoughSpace(needed: Int64, available: Int64)
    case io(String)
    
    var errorDescription: String? {
        switch self {
        case .notAZip:
            return "This file isn't a valid ZIP archive."
        case .truncated:
            return "The ZIP file is incomplete or damaged (it may not have finished downloading)."
        case .encrypted(let name):
            return "\"\(name)\" is password-protected, which isn't supported."
        case .unsupportedMethod(let name, let method):
            return "\"\(name)\" uses an unsupported compression method (\(method))."
        case .corrupt(let detail):
            return "The ZIP file is damaged: \(detail)"
        case .unsafePath(let name):
            return "The ZIP contains an unsafe path (\"\(name)\") and was not imported."
        case .cancelled:
            return "Import cancelled."
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough free space: the project needs about \(f.string(fromByteCount: needed)), but only \(f.string(fromByteCount: available)) is available."
        case .io(let message):
            return message
        }
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    
    /// Chainable: `crc = CRC32.update(crc, chunk)` starting from 0.
    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            table.withUnsafeBufferPointer { t in
                for byte in raw { c = t[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return ~c
    }
}

private extension Data {
    // Little-endian reads; `startIndex` keeps them correct for slices too.
    func u16(_ o: Int) -> UInt16 {
        UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8
    }
    func u32(_ o: Int) -> UInt32 {
        UInt32(u16(o)) | UInt32(u16(o + 2)) << 16
    }
    func u64(_ o: Int) -> UInt64 {
        UInt64(u32(o)) | UInt64(u32(o + 4)) << 32
    }
}

final class ZipArchiveReader {
    
    struct Entry {
        let path: String
        let flags: UInt16
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isDirectory: Bool
        let isSymlink: Bool
        var isEncrypted: Bool { flags & 0x1 != 0 }
    }
    
    let entries: [Entry]
    private let handle: FileHandle
    private let fileSize: UInt64
    private static let chunk = 256 * 1024
    
    init(url: URL) throws {
        let h: FileHandle
        do { h = try FileHandle(forReadingFrom: url) }
        catch { throw ZipError.io("Couldn't open the file: \(error.localizedDescription)") }
        let list: [Entry]
        let size: UInt64
        do {
            size = try h.seekToEnd()
            list = try ZipArchiveReader.readCentralDirectory(h, fileSize: size)
        } catch {
            try? h.close()
            throw error
        }
        self.entries = list
        self.handle = h
        self.fileSize = size
    }
    
    deinit { try? handle.close() }
    
    // MARK: Central directory
    
    private static func read(_ h: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try h.seek(toOffset: offset)
        guard let data = try h.read(upToCount: count), data.count == count else { throw ZipError.truncated }
        return data
    }
    
    private static func readCentralDirectory(_ h: FileHandle, fileSize: UInt64) throws -> [Entry] {
        guard fileSize >= 22 else { throw ZipError.notAZip }
        
        // End Of Central Directory: last 22 bytes + up to 64 KB of comment.
        let tailSize = Int(min(fileSize, 65_557))
        let tail = try read(h, at: fileSize - UInt64(tailSize), count: tailSize)
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail.u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        
        var totalEntries = UInt64(tail.u16(eocd + 10))
        var cdSize = UInt64(tail.u32(eocd + 12))
        var cdOffset = UInt64(tail.u32(eocd + 16))
        
        if totalEntries == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // Zip64: a 20-byte locator sits right before the EOCD and points at the real record.
            let locator = eocd - 20
            guard locator >= 0, tail.u32(locator) == 0x0706_4B50 else { throw ZipError.corrupt("missing Zip64 locator") }
            let record = try read(h, at: tail.u64(locator + 8), count: 56)
            guard record.u32(0) == 0x0606_4B50 else { throw ZipError.corrupt("bad Zip64 record") }
            totalEntries = record.u64(32)
            cdSize = record.u64(40)
            cdOffset = record.u64(48)
        }
        
        guard cdOffset <= fileSize, cdSize <= fileSize - cdOffset else { throw ZipError.truncated }
        guard cdSize <= 256 * 1024 * 1024 else { throw ZipError.corrupt("directory too large") }
        let cd = try read(h, at: cdOffset, count: Int(cdSize))
        
        var result: [Entry] = []
        result.reserveCapacity(Int(min(totalEntries, 100_000)))
        var p = 0
        var index: UInt64 = 0
        while index < totalEntries {
            guard p + 46 <= cd.count, cd.u32(p) == 0x0201_4B50 else { throw ZipError.corrupt("bad directory entry") }
            let versionMade = cd.u16(p + 4)
            let flags = cd.u16(p + 8)
            let method = cd.u16(p + 10)
            let crc = cd.u32(p + 16)
            var compressed = UInt64(cd.u32(p + 20))
            var uncompressed = UInt64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28))
            let extraLen = Int(cd.u16(p + 30))
            let commentLen = Int(cd.u16(p + 32))
            let externalAttrs = cd.u32(p + 38)
            var localOffset = UInt64(cd.u32(p + 42))
            
            let next = p + 46 + nameLen + extraLen + commentLen
            guard next <= cd.count else { throw ZipError.corrupt("bad directory entry length") }
            
            // Zip64 extended info: only the fields that were 0xFFFFFFFF are present, in this order.
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = cd.u16(e)
                let size = Int(cd.u16(e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if uncompressed == 0xFFFF_FFFF, q + 8 <= extraEnd { uncompressed = cd.u64(q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= extraEnd { compressed = cd.u64(q); q += 8 }
                    if localOffset == 0xFFFF_FFFF, q + 8 <= extraEnd { localOffset = cd.u64(q); q += 8 }
                }
                e += 4 + size
            }
            
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            let unixMode = (versionMade >> 8) == 3 ? (externalAttrs >> 16) : 0
            
            result.append(Entry(
                path: name, flags: flags, method: method, crc32: crc,
                compressedSize: compressed, uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                isDirectory: name.hasSuffix("/") || name.hasSuffix("\\"),
                isSymlink: (unixMode & 0o170000) == 0o120000
            ))
            p = next
            index += 1
        }
        return result
    }
    
    // MARK: Extraction
    
    /// Streams one entry to `destination`. `progress` gets the number of bytes just written.
    func extract(_ entry: Entry, to destination: URL,
                 progress: (Int) -> Void, isCancelled: () -> Bool) throws {
        guard !entry.isEncrypted else { throw ZipError.encrypted(entry.path) }
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedMethod(entry.path, entry.method) }
        
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw ZipError.io("Couldn't create \(destination.lastPathComponent).")
        }
        if entry.uncompressedSize == 0 {
            guard entry.crc32 == 0 else { throw ZipError.corrupt("\(entry.path) is empty but has a checksum") }
            return
        }
        
        // The local header's name/extra lengths can differ from the central directory's.
        let header = try ZipArchiveReader.read(handle, at: entry.localHeaderOffset, count: 30)
        guard header.u32(0) == 0x0403_4B50 else { throw ZipError.corrupt("bad local header for \(entry.path)") }
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        guard dataOffset <= fileSize, entry.compressedSize <= fileSize - dataOffset else { throw ZipError.truncated }
        
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        try handle.seek(toOffset: dataOffset)
        
        var crc: UInt32 = 0
        var written: UInt64 = 0
        let chunk = ZipArchiveReader.chunk
        
        func emit(_ data: Data) throws {
            crc = CRC32.update(crc, data)
            try out.write(contentsOf: data)
            written += UInt64(data.count)
            progress(data.count)
        }
        
        if entry.method == 0 {
            var remaining = entry.compressedSize
            while remaining > 0 {
                if isCancelled() { throw ZipError.cancelled }
                let n = Int(min(remaining, UInt64(chunk)))
                guard let data = try handle.read(upToCount: n), data.count == n else { throw ZipError.truncated }
                try emit(data)
                remaining -= UInt64(n)
            }
        } else {
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
                throw ZipError.corrupt("couldn't start decompression")
            }
            defer { compression_stream_destroy(stream) }
            
            let src = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { src.deallocate(); dst.deallocate() }
            
            stream.pointee.src_ptr = UnsafePointer(src)
            stream.pointee.src_size = 0
            stream.pointee.dst_ptr = dst
            stream.pointee.dst_size = chunk
            
            var remaining = entry.compressedSize
            var finished = false
            while !finished {
                if isCancelled() { throw ZipError.cancelled }
                
                if stream.pointee.src_size == 0 && remaining > 0 {
                    let n = Int(min(remaining, UInt64(chunk)))
                    guard let data = try handle.read(upToCount: n), data.count == n else { throw ZipError.truncated }
                    data.copyBytes(to: src, count: n)
                    stream.pointee.src_ptr = UnsafePointer(src)
                    stream.pointee.src_size = n
                    remaining -= UInt64(n)
                }
                
                // FINALIZE once no more input will ever be supplied.
                let flags: Int32 = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(stream, flags)
                
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 {
                    try emit(Data(bytes: dst, count: produced))
                    stream.pointee.dst_ptr = dst
                    stream.pointee.dst_size = chunk
                }
                
                switch status {
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.pointee.src_size == 0 && remaining == 0 {
                        throw ZipError.corrupt("\(entry.path) ends unexpectedly")
                    }
                case COMPRESSION_STATUS_END:
                    finished = true
                default:
                    throw ZipError.corrupt("\(entry.path) can't be decompressed")
                }
            }
        }
        
        guard written == entry.uncompressedSize else { throw ZipError.corrupt("\(entry.path) has the wrong size") }
        guard crc == entry.crc32 else { throw ZipError.corrupt("\(entry.path) failed its checksum") }
    }
}
