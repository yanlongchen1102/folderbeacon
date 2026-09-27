import Foundation

nonisolated struct SearchRoot: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var lastKnownPath: String
    var bookmarkData: Data?
    var volumeUUID: String?
    var isEnabled: Bool
    var includeHiddenFolders: Bool
    var addedAt: Date

    var url: URL { URL(fileURLWithPath: lastKnownPath, isDirectory: true) }
}

nonisolated enum SearchRootAvailability: String, Codable, Sendable {
    case available, offline, permissionRequired, missing, unsupported
}

nonisolated enum SearchRootIndexState: String, Codable, Sendable {
    case notStarted, scanning, ready, updating, paused, incomplete, failed
}

nonisolated struct FolderIndexRootSnapshot: Identifiable, Sendable {
    var root: SearchRoot
    var availability: SearchRootAvailability
    var state: SearchRootIndexState
    var indexedFolderCount: Int
    var lastFullScanAt: Date?
    var detail: String?
    var id: UUID { root.id }
}

nonisolated struct IndexedFolder: Sendable {
    let relativePath: String
    let parentRelativePath: String?
    let name: String
    let normalizedName: String
    let normalizedPath: String
    let resourceIdentifier: Data?
}
