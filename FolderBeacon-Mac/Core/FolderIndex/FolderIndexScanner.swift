import Foundation

/// Blocking filesystem work belongs on a dedicated OperationQueue, never an actor executor.
final class FolderIndexScanner: @unchecked Sendable {
    private let policy = FolderIndexPolicy()

    func scan(root: SearchRoot, startingAt relativePath: String = "", isCancelled: @escaping @Sendable () -> Bool, consume: @escaping @Sendable ([IndexedFolder]) async -> Void, unreadable: @escaping @Sendable (String) async -> Void) async throws {
        let rootURL = root.url.standardizedFileURL
        let startURL = relativePath.isEmpty ? rootURL : rootURL.appendingPathComponent(relativePath, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileResourceIdentifierKey]
        var pending = [startURL]
        var batch: [IndexedFolder] = []
        let startName = relativePath.isEmpty ? root.displayName : startURL.lastPathComponent
        let parent = relativePath.isEmpty ? nil : (relativePath as NSString).deletingLastPathComponent
        let rootRecord = IndexedFolder(relativePath: relativePath, parentRelativePath: parent?.isEmpty == true ? "" : parent, name: startName, normalizedName: FolderSearchNormalizer.normalize(startName), normalizedPath: FolderSearchNormalizer.normalize(relativePath), resourceIdentifier: nil)
        batch.append(rootRecord)

        while let directory = pending.popLast() {
            if isCancelled() { throw CancellationError() }
            // Permission changes on a descendant must not invalidate a complete
            // Home scan. Keep prior records for that subtree until a later scan can read it.
            guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsSubdirectoryDescendants]) else {
                let relative = directory.path.dropFirst(rootURL.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                await unreadable(relative)
                continue
            }
            for child in children {
                if isCancelled() { throw CancellationError() }
                let relative = child.path.dropFirst(rootURL.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let values = try? child.resourceValues(forKeys: keys) else {
                    await unreadable(relative)
                    continue
                }
                guard policy.shouldIndex(child, values: values, root: root) else { continue }
                let parent = (relative as NSString).deletingLastPathComponent
                let identifier = values.fileResourceIdentifier.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) }
                batch.append(IndexedFolder(relativePath: relative, parentRelativePath: parent.isEmpty ? "" : parent, name: child.lastPathComponent, normalizedName: FolderSearchNormalizer.normalize(child.lastPathComponent), normalizedPath: FolderSearchNormalizer.normalize(relative), resourceIdentifier: identifier))
                if policy.shouldDescend(into: values) { pending.append(child) }
                if batch.count >= 300 { await consume(batch); batch.removeAll(keepingCapacity: true) }
            }
        }
        if !batch.isEmpty { await consume(batch) }
    }
}
