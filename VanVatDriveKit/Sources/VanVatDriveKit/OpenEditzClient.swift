import Foundation

/// The OpenEditz client: the part of the Drive API the editor needs, locked to the user's protected OpenEditz folder.
///
/// Everything starts from `root()` (POST /system/openeditz) and only follows children from there, so the editor can
/// never read or write outside OpenEditz — even though the same account owns the rest of the Drive.
/// Typical use from the DoubleClips Storage tab:
///
///     let oe = OpenEditzClient(client: drive)
///     let projects = try await oe.ensureFolder(path: ["Projects"])
///     let node = try await oe.upload(fileURL: zipURL, into: projects)       // resumable, 512 MB cap
///     let items = try await oe.list(projects)
///     let local = try await oe.download(node)
public actor OpenEditzClient {
    private let client: DriveClient
    private var rootNode: DriveNode?
    private var inside: Set<String> = []     // ids proven to live under OpenEditz

    public init(client: DriveClient) { self.client = client }

    /// The OpenEditz folder (created on first use).
    public func root() async throws -> DriveNode {
        if let rootNode { return rootNode }
        let node = try await client.ensureOpenEditz()
        rootNode = node
        inside = [node.id]
        return node
    }

    /// Children of a folder inside OpenEditz (nil = the OpenEditz folder itself).
    public func list(_ folder: DriveNode? = nil) async throws -> [DriveNode] {
        let parent = try await scoped(folder)
        let listing = try await client.list(parentId: parent.id)
        for n in listing.items { inside.insert(n.id) }
        return listing.items
    }

    public func createFolder(named name: String, in folder: DriveNode? = nil) async throws -> DriveNode {
        let parent = try await scoped(folder)
        let node = try await client.createFolder(parentId: parent.id, name: name)
        inside.insert(node.id)
        return node
    }

    /// Walks/creates `OpenEditz/<a>/<b>/...` and returns the last folder.
    public func ensureFolder(path: [String]) async throws -> DriveNode {
        var current = try await root()
        for name in path {
            let children = try await list(current)
            if let existing = children.first(where: { $0.isFolder && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                current = existing
            } else {
                current = try await createFolder(named: name, in: current)
            }
        }
        return current
    }

    /// Resumable upload into a folder inside OpenEditz.
    public func upload(fileURL: URL, into folder: DriveNode? = nil, name: String? = nil,
                       progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> DriveNode {
        let parent = try await scoped(folder)
        let node = try await ResumableUpload.run(client: client, fileURL: fileURL, parentId: parent.id, name: name, progress: progress)
        inside.insert(node.id)
        return node
    }

    public func download(_ node: DriveNode) async throws -> URL {
        try requireInside(node)
        return try await client.download(node)
    }

    public func rename(_ node: DriveNode, to name: String) async throws -> DriveNode {
        try requireInside(node)
        return try await client.rename(node, to: name)
    }

    public func trash(_ node: DriveNode) async throws {
        try requireInside(node)
        try await client.trash(node)
        inside.remove(node.id)
    }

    /// Deletes for good (trash + purge) so the space comes back right away. Folders go with everything inside.
    public func delete(_ node: DriveNode) async throws {
        try requireInside(node)
        try await client.trash(node)
        try await client.purge(node)
        inside.remove(node.id)
    }

    // MARK: - Scope

    private func scoped(_ folder: DriveNode?) async throws -> DriveNode {
        guard let folder else { return try await root() }
        try requireInside(folder)
        return folder
    }

    private func requireInside(_ node: DriveNode) throws {
        guard inside.contains(node.id) else {
            throw DriveError(status: 403, code: "outside_openeditz", message: "That item is not inside the OpenEditz folder.")
        }
    }
}
