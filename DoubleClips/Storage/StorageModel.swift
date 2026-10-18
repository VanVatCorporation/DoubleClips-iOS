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
    }

    struct BackupState {
        enum Phase: Equatable { case zipping, uploading, done, failed(String) }
        let title: String
        var phase: Phase
        var fraction: Double
    }

    @Published private(set) var items: [DriveNode] = []
    /// Folders entered below OpenEditz (empty = the OpenEditz folder itself).
    @Published private(set) var trail: [DriveNode] = []
    @Published private(set) var me: Me?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var busyText: String?
    @Published private(set) var uploads: [UploadRow] = []
    @Published private(set) var backup: BackupState?

    private let oe = DoubleClipsDrive.openEditz
    private var backupTask: Task<Void, Never>?
    private var backupCancellation: ProjectImporter.Cancellation?

    var currentFolder: DriveNode? { trail.last }
    var freeBytes: Int64 { max(0, (me?.quotaBytes ?? 0) - (me?.usedBytes ?? 0)) }
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

    func download(_ node: DriveNode) async -> URL? {
        busyText = "Downloading…"
        defer { busyText = nil }
        do { return try await oe.download(node) }
        catch { handle(error); return nil }
    }

    /// Hands a downloaded project ZIP to the normal import (IncomingFileCenter -> HomeView -> ProjectImporter).
    func restore(_ node: DriveNode) async {
        guard let url = await download(node) else { return }
        IncomingFileCenter.shared.receive(url)
    }

    // MARK: - Upload files

    func upload(_ urls: [URL]) {
        let copies = Self.copyIntoSandbox(urls)
        for url in copies {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > freeBytes {
                try? FileManager.default.removeItem(at: url)
                errorMessage = "Not enough space for “\(url.lastPathComponent)”: \(Self.bytes(freeBytes)) left."
                continue
            }
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
                    finishUpload(row.id, .failed(error.localizedDescription))
                }
                try? FileManager.default.removeItem(at: url)
                await reload()
            }
        }
    }

    func clearFinishedUploads() {
        uploads.removeAll { $0.state != .running }
    }

    private func setLoaded(_ id: UUID, _ value: Int64) {
        guard let i = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[i].loaded = min(uploads[i].size, value)
    }

    private func finishUpload(_ id: UUID, _ state: UploadRow.State) {
        guard let i = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[i].state = state
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
                if Task.isCancelled { backup = nil } else { setBackup(phase: .failed(error.localizedDescription)) }
            }
            ProjectExporter.cleanOldFiles()
        }
    }

    func cancelBackup() {
        backupCancellation?.cancel()
        backupTask?.cancel()
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
