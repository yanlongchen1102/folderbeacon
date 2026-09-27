import Foundation

nonisolated enum FolderSearchSource: Hashable, Sendable { case directPath, favorite, recent, finder, localIndex, spotlight }
nonisolated enum FolderResultAvailability: Sendable { case available, offline, inaccessible }

nonisolated struct FolderSearchResult: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let rootID: UUID?
    var sources: Set<FolderSearchSource>
    let availability: FolderResultAvailability
    var score: Int
}

nonisolated struct FolderSearchContext: Sendable {
    var finderFolders: [(String, URL)] = []
    var favorites: [(String, URL)] = []
    var recent: [(String, URL, Date)] = []
}

nonisolated struct FolderSearchResponse: Sendable {
    let results: [FolderSearchResult]
    let hasMore: Bool
    let configuredRootCount: Int
    let isIndexing: Bool
    let hasIncompleteRoots: Bool
}
