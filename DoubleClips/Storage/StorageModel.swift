import SwiftUI
import Combine

/// State of the Storage tab: browsing OpenEditz, uploading, backing projects up, restoring them.
@MainActor
final class StorageModel: ObservableObject {

    struct UploadRow: Identifiable {
        enum State: Equatable { case running, done, failed(String) }
        let id = UUID()
        let name: String
        let size: Int64
        var loaded: Int64 = 0
        var state: State = .running
        /// The server refused for a quota/plan reason: the row offers "Get more resources".
        var quotaFailure = false
    }

    struct BackupState {
        /// `.warning`: the ZIP probably won't fit today's upload allowance; waiting for "Continue anyway" or "Cancel".
        enum Phase: Equatable { case zipping, uploading, warning(String), done, failed(String) }
        let title: String
        var phase: Phase
        var fraction: Double
        var quotaFailure = false
    }

    @Published private(set) var items: [DriveNode] = []
    /// Folders entered below OpenEditz (empty = the OpenEditz folder itself).
    @Published private(set) var trail: [DriveNode] = []
    @Published private(set) var me: Me?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// The error above is a quota/plan limit: the alert offers "Get more resources".
    @Published var errorIsQuota = false
    /// "Continue anyway" popup for an upload/download that probably won't fit today's allowance.
    @Published var warning: QuotaWarning?
    @Published var busyText: String?
    @Published private(set) var uploads: [UploadRow] = []
    @Published private(set) var backup: BackupState?

    private let oe = DoubleClipsDrive.openEditz
    private var backupTask: Task<Void, Never>?
    private var backupCancellation: ProjectImporter.Cancellation?
    private var backupWarningContinuation: CheckedContinuation<Bool, Never>?

    var currentFolder: DriveNode? { trail.last }
    var freeBytes: Int64 { max(0, (me?.quotaBytes ?? 0) - (me?.usedBytes ?? 0)) }
    var uploadFree: Int64 { me?.usage?.uploadFree ?? .max }
    var downloadFree: Int64 { me?.usage?.downloadFree ?? .max }
    var hasSession: Bool { DoubleClipsDrive.sessionToken() != nil }

    // MARK: - Browse

    func reload() async {
        guard hasSession else { items = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await oe.list(currentFolder)
            items = list.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            me = try? await DoubleClipsDrive.client.me()
            errorMessage = nil
        } catch {
            handle(error)
        }
    }

    func enter(_ folder: DriveNode) async {
        trail.append(folder)
        await reload()
    }

    /// depth 0 = the OpenEditz folder.
    func go(toDepth depth: Int) async {
        trail = Array(trail.prefix(max(0, depth)))
        await reload()
    }

    // MARK: - Changes

    func createFolder(named name: String) async {
        await perform { _ = try await self.oe.createFolder(named: name, in: self.currentFolder) }
    }

    func rename(_ node: DriveNode, to name: String) async {
        await perform { _ = try await self.oe.rename(node, to: name) }
    }

    /// Deletes for good, so the space is free again straight away.
    func delete(_ node: DriveNode) async {
        await perform { try await self.oe.delete(node) }
    }

    private func perform(_ work: () async throws -> Void) async {
        do { try await work(); await reload() }
        catch { handle(error) }
    }

    // MARK: - Download / restore

    /// Runs `action` (a download) now, or after "Continue anyway" when the file probably won't fit today's download allowance.
    func guardDownload(_ node: DriveNode, _ action: @escaping () -> Void) {
        let free = downloadFree
        if node.size > free {
            warning = QuotaWarning(title: QuotaText.downloadTitle, message: QuotaText.download(size: node.size, free: free), onConfirm: action)
        } else {
            action()
        }
    }

    func download(_ node: DriveNode) async -> URL? {
        busyText = "Downloading…"
        defer { busyText = nil }
        do {
            let url = try await oe.download(node)
            await refreshQuota()                 // the download spent part of today's allowance
            return url
        } catch { handle(error); return nil }
    }

    /// Hands a downloaded project ZIP to the normal import (IncomingFileCenter -> HomeView -> ProjectImporter).
    func restore(_ node: DriveNode) async {
        guard let url = await download(node) else { return }
        IncomingFileCenter.shared.receive(url)
    }

    // MARK: - Upload files

    func upload(_ urls: [URL]) {
        var copies = Self.copyIntoSandbox(urls)
        // Not enough storage cannot work: stop with an upgrade offer. The daily cap only warns (like the web Drive).
        var kept: [URL] = []
        for url in copies {
            let size = Self.size(of: url)
            if size > freeBytes {
                try? FileManager.default.removeItem(at: url)
                errorIsQuota = true
                errorMessage = "Not enough space for “\(url.lastPathComponent)”: \(Self.bytes(freeBytes)) left."
            } else {
                kept.append(url)
            }
        }
        copies = kept
        guard !copies.isEmpty else { return }

        let total = copies.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        let free = uploadFree
        if total > free {
            let pending = copies
            warning = QuotaWarning(
                title: QuotaText.uploadTitle,
                message: QuotaText.upload(size: total, free: free),
                onConfirm: { [weak self] in self?.start(uploading: pending) },
                onCancel: { pending.forEach { try? FileManager.default.removeItem(at: $0) } })
            return
        }
        start(uploading: copies)
    }

    private func start(uploading copies: [URL]) {
        for url in copies {
            let size = Self.size(of: url)
            let row = UploadRow(name: url.lastPathComponent, size: size)
            uploads.append(row)
            let folder = currentFolder
            Task {
                do {
                    _ = try await oe.upload(fileURL: url, into: folder) { [weak self] sent in
                        Task { @MainActor in self?.setLoaded(row.id, sent) }
                    }
                    finishUpload(row.id, .done)
                } catch {
                    finishUpload(row.id, .failed(error.localizedDescription), quota: (error as? DriveError)?.isQuotaLimit ?? false)
                }
                try? FileManager.default.removeItem(at: url)
                await reload()
            }
        }
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    func clearFinishedUploads() {
        uploads.removeAll { $0.state != .running }
    }

    private func setLoaded(_ id: UUID, _ value: Int64) {
        guard let i = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[i].loaded = min(uploads[i].size, value)
    }

    private func finishUpload(_ id: UUID, _ state: UploadRow.State, quota: Bool = false) {
        guard let i = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[i].state = state
        uploads[i].quotaFailure = quota
        if state == .done { uploads[i].loaded = uploads[i].size }
    }

    // MARK: - Back up a project (ZIP) to OpenEditz/Projects

    func startBackup(_ project: ProjectData) {
        guard backup == nil || backup?.phase == .done || isFailed(backup) else { return }
        let cancellation = ProjectImporter.Cancellation()
        backupCancellation = cancellation
        backup = BackupState(title: project.projectTitle, phase: .zipping, fraction: 0)

        backupTask = Task {
            do {
                let zip: URL = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let url = try ProjectExporter.exportZip(project: project, progress: { [weak self] p in
                                Task { @MainActor in self?.setBackup(fraction: p.fraction) }
                            }, cancellation: cancellation)
                            continuation.resume(returning: url)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                defer { try? FileManager.default.removeItem(at: zip) }

                let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? 0
                await refreshQuota()
                if size > freeBytes {
                    throw DriveError(status: 413, code: "quota_exceeded",
                                     message: "The backup is \(Self.bytes(size)) but only \(Self.bytes(freeBytes)) of storage is left.")
                }

                // The daily upload cap only warns: the user can still continue (the server has the final say).
                let freeToday = uploadFree
                if size > freeToday {
                    let message = QuotaText.upload(size: size, free: freeToday)
                    setBackup(phase: .warning(message))
                    let proceed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in backupWarningContinuation = c }
                    backupWarningContinuation = nil
                    if !proceed { throw CancellationError() }
                }

                setBackup(phase: .uploading, fraction: 0)
                let folder = try await oe.ensureFolder(path: ["Projects"])
                let name = "\(ProjectData.sanitizedFolderName(project.projectTitle)) \(Self.stamp()).zip"
                _ = try await oe.upload(fileURL: zip, into: folder, name: name) { [weak self] sent in
                    Task { @MainActor in self?.setBackup(fraction: Double(sent) / Double(max(size, 1))) }
                }
                setBackup(phase: .done, fraction: 1)
                await reload()
            } catch ZipError.cancelled {
                backup = nil
            } catch is CancellationError {
                backup = nil
            } catch {
                if Task.isCancelled { backup = nil } else {
                    setBackup(phase: .failed(error.localizedDescription))
                    if (error as? DriveError)?.isQuotaLimit == true { backup?.quotaFailure = true }
                }
            }
            ProjectExporter.cleanOldFiles()
        }
    }

    func cancelBackup() {
        backupCancellation?.cancel()
        backupTask?.cancel()
        backupWarningContinuation?.resume(returning: false)
        backupWarningContinuation = nil
    }

    /// Answers the "Continue anyway" prompt shown inside the backup sheet.
    func answerBackupWarning(continue proceed: Bool) {
        backupWarningContinuation?.resume(returning: proceed)
        backupWarningContinuation = nil
        if proceed { setBackup(phase: .uploading, fraction: 0) }
    }

    func dismissBackup() { backup = nil }

    private func isFailed(_ b: BackupState?) -> Bool {
        if case .failed = b?.phase { return true }
        return false
    }

    private func setBackup(phase: BackupState.Phase? = nil, fraction: Double? = nil) {
        guard var b = backup else { return }
        if let phase { b.phase = phase }
        if let fraction { b.fraction = fraction }
        backup = b
    }

    private func refreshQuota() async {
        if let fresh = try? await DoubleClipsDrive.client.me() { me = fresh }
    }

    // MARK: - Helpers

    private func handle(_ error: Error) {
        if let drive = error as? DriveError, drive.isUnauthorized {
            errorMessage = "Your session expired. Please sign in again from the Profile tab."
        } else if (error as? URLError)?.code == .cancelled {
            return
        } else {
            errorIsQuota = (error as? DriveError)?.isQuotaLimit ?? false
            errorMessage = error.localizedDescription
        }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: Date())
    }

    /// Files from the document picker are security-scoped: copy them into our sandbox before uploading.
    private static func copyIntoSandbox(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
                out.append(dest)
            } catch { continue }
        }
        return out
    }
}
