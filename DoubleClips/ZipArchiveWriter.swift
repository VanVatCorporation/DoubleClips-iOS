import Foundation
import Compression

// MARK: - Minimal streaming ZIP writer
//
// The inverse of ZipArchiveReader (same reasons for not using a dependency: Foundation has no
// zip API, and a package has to be added by hand in Xcode).
//
// What it writes, and why:
//   - Sizes and CRC are NOT deferred to a data descriptor (the trick Java's ZipOutputStream
//     uses). The output is a real file, so each local header is written with placeholders and
//     patched once the entry is done. That keeps the archive readable by *every* unzipper,
//     including Android's `ZipInputStream` (the Android importer), which cannot read STORED
//     entries that rely on a data descriptor.
//   - Each entry is STORED (method 0) or DEFLATE (method 8, Apple's COMPRESSION_ZLIB is raw
//     deflate, exactly what ZIP stores). Video/audio/images are already compressed, so the
//     caller stores those and deflates only the small text files.
//   - Entries stream in 256 KB chunks: a multi-GB video never sits in memory.
//   - The central directory supports Zip64 (more than 65535 entries, or an archive past 4 GB),
//     mirroring what ZipArchiveReader accepts. A single FILE must still be under 4 GB: local
//     headers are patched in place and have no room for a Zip64 extra field.
//   - Names are UTF-8 (general-purpose flag bit 11), Unix permissions are recorded.

final class ZipArchiveWriter {
    
    private struct Record {
        let name: Data
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let dosTime: UInt16
        let dosDate: UInt16
    }
    
    private let url: URL
    private let handle: FileHandle
    private var position: UInt64 = 0
    private var records: [Record] = []
    private var isClosed = false
    
    private static let chunk = 256 * 1024
    private static let max32: UInt64 = 0xFFFF_FFFF
    
    var entryCount: Int { records.count }
    
    init(url: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw ZipError.io("Couldn't create the ZIP file.")
        }
        let h: FileHandle
        do { h = try FileHandle(forWritingTo: url) }
        catch { throw ZipError.io("Couldn't open the ZIP file for writing: \(error.localizedDescription)") }
        self.url = url
        self.handle = h
    }
    
    deinit { closeIfNeeded() }
    
    private func closeIfNeeded() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }
    
    /// Closes and deletes the half-written file (cancel / error).
    func abort() {
        closeIfNeeded()
        try? FileManager.default.removeItem(at: url)
    }
    
    // MARK: Writing
    
    private func write(_ data: Data) throws {
        do { try handle.write(contentsOf: data) }
        catch { throw ZipError.io("Couldn't write the ZIP file (is the device out of space?): \(error.localizedDescription)") }
        position += UInt64(data.count)
    }
    
    /// Streams one file into the archive. `progress` gets the number of source bytes just consumed.
    func addFile(at source: URL, as entryPath: String, modified: Date?, store: Bool,
                 progress: (Int) -> Void, isCancelled: () -> Bool) throws {
        let nameData = Data(entryPath.utf8)
        guard !nameData.isEmpty, nameData.count <= 0xFFFF else {
            throw ZipError.io("A file name is too long to store: \(entryPath)")
        }
        
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let declaredSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard declaredSize < ZipArchiveWriter.max32 else {
            throw ZipError.io("\"\(source.lastPathComponent)\" is 4 GB or larger, which the ZIP format used here can't store.")
        }
        
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) }
        catch { throw ZipError.io("Couldn't read \(source.lastPathComponent): \(error.localizedDescription)") }
        defer { try? input.close() }
        
        let method: UInt16 = (store || declaredSize == 0) ? 0 : 8
        let (dosTime, dosDate) = ZipArchiveWriter.dosDateTime(modified ?? Date())
        let headerOffset = position
        
        var header = Data()
        header.appendLE(UInt32(0x0403_4B50))     // local file header signature
        header.appendLE(UInt16(20))              // version needed
        header.appendLE(UInt16(0x0800))          // flags: UTF-8 names, no data descriptor
        header.appendLE(method)
        header.appendLE(dosTime)
        header.appendLE(dosDate)
        header.appendLE(UInt32(0))               // crc32      (patched below)
        header.appendLE(UInt32(0))               // compressed (patched below)
        header.appendLE(UInt32(0))               // uncompressed (patched below)
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0))               // extra length
        header.append(nameData)
        try write(header)
        
        var crc: UInt32 = 0
        var rawSize: UInt64 = 0
        let dataStart = position
        let chunk = ZipArchiveWriter.chunk
        
        func consumed(_ data: Data) throws {
            crc = CRC32.update(crc, data)
            rawSize += UInt64(data.count)
            guard rawSize < ZipArchiveWriter.max32 else {
                throw ZipError.io("\"\(source.lastPathComponent)\" grew past 4 GB while it was being added.")
            }
            progress(data.count)
        }
        
        if method == 0 {
            while true {
                if isCancelled() { throw ZipError.cancelled }
                guard let data = try input.read(upToCount: chunk), !data.isEmpty else { break }
                try consumed(data)
                try write(data)
            }
        } else {
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
                throw ZipError.io("Couldn't start compression.")
            }
            defer { compression_stream_destroy(stream) }
            
            let src = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { src.deallocate(); dst.deallocate() }
            
            stream.pointee.src_ptr = UnsafePointer(src)
            stream.pointee.src_size = 0
            stream.pointee.dst_ptr = dst
            stream.pointee.dst_size = chunk
            
            var inputDone = false
            var finished = false
            while !finished {
                if isCancelled() { throw ZipError.cancelled }
                
                if stream.pointee.src_size == 0 && !inputDone {
                    if let data = try input.read(upToCount: chunk), !data.isEmpty {
                        try consumed(data)
                        data.copyBytes(to: src, count: data.count)
                        stream.pointee.src_ptr = UnsafePointer(src)
                        stream.pointee.src_size = data.count
                    } else {
                        inputDone = true
                    }
                }
                
                // FINALIZE once no more input will ever be supplied.
                let flags: Int32 = inputDone ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(stream, flags)
                
                let produced = chunk - stream.pointee.dst_size
                if produced > 0 {
                    try write(Data(bytes: dst, count: produced))
                    stream.pointee.dst_ptr = dst
                    stream.pointee.dst_size = chunk
                }
                
                switch status {
                case COMPRESSION_STATUS_OK: break
                case COMPRESSION_STATUS_END: finished = true
                default: throw ZipError.io("Couldn't compress \(source.lastPathComponent).")
                }
            }
        }
        
        let packedSize = position - dataStart
        guard packedSize < ZipArchiveWriter.max32 else {
            throw ZipError.io("\"\(source.lastPathComponent)\" is too large to store.")
        }
        
        // Patch crc32 / sizes into the local header (offset 14), then return to the end.
        var patch = Data()
        patch.appendLE(crc)
        patch.appendLE(UInt32(packedSize))
        patch.appendLE(UInt32(rawSize))
        do {
            try handle.seek(toOffset: headerOffset + 14)
            try handle.write(contentsOf: patch)
            try handle.seek(toOffset: position)
        } catch {
            throw ZipError.io("Couldn't finish writing the ZIP file: \(error.localizedDescription)")
        }
        
        records.append(Record(name: nameData, method: method, crc32: crc,
                              compressedSize: packedSize, uncompressedSize: rawSize,
                              localHeaderOffset: headerOffset, dosTime: dosTime, dosDate: dosDate))
    }
    
    /// Writes the central directory and closes the file. The archive is only valid after this.
    func finish() throws {
        let directoryStart = position
        
        var directory = Data()
        for r in records {
            let zip64Offset = r.localHeaderOffset >= ZipArchiveWriter.max32
            directory.appendLE(UInt32(0x0201_4B50))                    // central directory signature
            directory.appendLE(UInt16((3 << 8) | 20))                  // made by: Unix, spec 2.0
            directory.appendLE(UInt16(zip64Offset ? 45 : 20))          // version needed
            directory.appendLE(UInt16(0x0800))                         // flags: UTF-8 names
            directory.appendLE(r.method)
            directory.appendLE(r.dosTime)
            directory.appendLE(r.dosDate)
            directory.appendLE(r.crc32)
            directory.appendLE(UInt32(r.compressedSize))
            directory.appendLE(UInt32(r.uncompressedSize))
            directory.appendLE(UInt16(r.name.count))
            directory.appendLE(UInt16(zip64Offset ? 12 : 0))           // extra length
            directory.appendLE(UInt16(0))                              // comment length
            directory.appendLE(UInt16(0))                              // disk number
            directory.appendLE(UInt16(0))                              // internal attributes
            directory.appendLE(UInt32(0o100644) << 16)                 // external attributes: -rw-r--r--
            directory.appendLE(zip64Offset ? UInt32(0xFFFF_FFFF) : UInt32(r.localHeaderOffset))
            directory.append(r.name)
            if zip64Offset {
                directory.appendLE(UInt16(0x0001))                     // Zip64 extended info
                directory.appendLE(UInt16(8))
                directory.appendLE(r.localHeaderOffset)
            }
        }
        try write(directory)
        let directorySize = position - directoryStart
        
        let total = UInt64(records.count)
        let needsZip64 = total >= 0xFFFF
            || directoryStart >= ZipArchiveWriter.max32
            || directorySize >= ZipArchiveWriter.max32
        
        var tail = Data()
        if needsZip64 {
            let zip64RecordOffset = position
            tail.appendLE(UInt32(0x0606_4B50))     // Zip64 end of central directory record
            tail.appendLE(UInt64(44))
            tail.appendLE(UInt16((3 << 8) | 45))
            tail.appendLE(UInt16(45))
            tail.appendLE(UInt32(0))
            tail.appendLE(UInt32(0))
            tail.appendLE(total)
            tail.appendLE(total)
            tail.appendLE(directorySize)
            tail.appendLE(directoryStart)
            
            tail.appendLE(UInt32(0x0706_4B50))     // Zip64 locator
            tail.appendLE(UInt32(0))
            tail.appendLE(zip64RecordOffset)
            tail.appendLE(UInt32(1))
        }
        tail.appendLE(UInt32(0x0605_4B50))         // end of central directory
        tail.appendLE(UInt16(0))
        tail.appendLE(UInt16(0))
        tail.appendLE(needsZip64 ? UInt16(0xFFFF) : UInt16(total))
        tail.appendLE(needsZip64 ? UInt16(0xFFFF) : UInt16(total))
        tail.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(directorySize))
        tail.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(directoryStart))
        tail.appendLE(UInt16(0))                   // comment length
        try write(tail)
        
        do {
            try handle.synchronize()
            isClosed = true
            try handle.close()
        } catch {
            throw ZipError.io("Couldn't finish writing the ZIP file: \(error.localizedDescription)")
        }
    }
    
    // MARK: Helpers
    
    /// MS-DOS date/time (local time, 2-second resolution, 1980 minimum), as ZIP stores it.
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = min(max((c.year ?? 1980), 1980), 2107)
        let month = min(max((c.month ?? 1), 1), 12)
        let day = min(max((c.day ?? 1), 1), 31)
        let hour = min(max((c.hour ?? 0), 0), 23)
        let minute = min(max((c.minute ?? 0), 0), 59)
        let second = min(max((c.second ?? 0), 0), 59)
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        return (dosTime, dosDate)
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
    mutating func appendLE(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
    mutating func appendLE(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { append(UInt8((v >> UInt64(shift)) & 0xFF)) }
    }
}
