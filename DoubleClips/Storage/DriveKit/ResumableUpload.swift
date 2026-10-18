// Embedded copy of VanVatDriveKit (Sources/VanVatDriveKit/ResumableUpload.swift (without UploadQueue)) so DoubleClips needs no package setup.
// Keep in sync with the package; replace with the package dependency later if you prefer.
import Foundation

/// One chunked, resumable upload: POST /uploads, PUT chunks (Upload-Offset), POST /complete.
/// After a network error it asks the server how far it got and continues from there.
public enum ResumableUpload {
    public static func run(client: DriveClient, fileURL: URL, parentId: String?, name: String? = nil, mimeType: String? = nil,
                           progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> DriveNode {
        let size = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let session = try await client.createUpload(parentId: parentId, name: name ?? fileURL.lastPathComponent, size: size, mimeType: mimeType)

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            var offset = session.received
            var attempts = 0
            while offset < size {
                try Task.checkCancellation()
                let length = Int(min(Int64(session.chunkSize), size - offset))
                try handle.seek(toOffset: UInt64(offset))
                guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else {
                    throw DriveError(status: 0, code: "read", message: "Could not read the file.")
                }
                do {
                    let base = offset
                    let result = try await client.putChunk(uploadId: session.uploadId, offset: offset, data: chunk) { sent in progress(base + sent) }
                    switch result {
                    case .ok(let newOffset): offset = newOffset; attempts = 0
                    case .mismatch(let received): offset = received       // the server knows better
                    }
                    progress(offset)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if error is DriveError { throw error }                 // real server answer (quota, forbidden...)
                    attempts += 1
                    if attempts > 5 { throw error }
                    try await Task.sleep(nanoseconds: UInt64(attempts) * 800_000_000)
                    offset = try await client.uploadReceived(uploadId: session.uploadId)
                }
            }
            return try await client.completeUpload(uploadId: session.uploadId)
        } catch {
            // Detached: this task may already be cancelled, and the cleanup call must still go out.
            Task.detached { await client.cancelUpload(uploadId: session.uploadId) }
            throw error
        }
    }
}

