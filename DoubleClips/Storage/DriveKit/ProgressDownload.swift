import Foundation

/// One file download with byte progress and cancellation. `URLSession.download(for:)` reports nothing while it runs, so this uses a
/// download task with a delegate. Cancelling the awaiting Task cancels the transfer (the partial data is discarded) and throws
/// `CancellationError`. One instance = one download.
final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var movedFile: URL?
    private var lastReport = Date.distantPast
    
    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }
    
    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, URLResponse), Error>) in
                    let task = session.downloadTask(with: request)
                    lock.lock(); self.task = task; self.continuation = cont; lock.unlock()
                    task.resume()
                    if Task.isCancelled { task.cancel() }            // cancelled before it even started
                }
            } onCancel: {
                lock.lock(); let task = self.task; lock.unlock()
                task?.cancel()
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
    
    // MARK: URLSessionDownloadDelegate
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // A few updates a second are plenty for a progress bar.
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastReport) >= 0.1
        if due { lastReport = now }
        lock.unlock()
        guard due else { return }
        progress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns: keep the file under our own name.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: location, to: kept) } catch { return }
        lock.lock(); movedFile = kept; lock.unlock()
        let size = (try? FileManager.default.attributesOfItem(atPath: kept.path)[.size] as? Int64) ?? 0
        progress(size, size)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation; continuation = nil
        let file = movedFile; movedFile = nil
        lock.unlock()
        guard let cont else { return }
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            cont.resume(throwing: error)
        } else if let file, let response = task.response {
            cont.resume(returning: (file, response))
        } else {
            cont.resume(throwing: URLError(.cannotParseResponse))
        }
    }
}
