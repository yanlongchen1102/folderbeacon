import Combine
import Foundation

@MainActor
final class QuickPanelSearchModel: ObservableObject {
    @Published private(set) var response = FolderSearchResponse(results: [], hasMore: false, configuredRootCount: 0, isIndexing: false, hasIncompleteRoots: false)
    @Published private(set) var isSearching = false
    private let service: FolderSearchService
    private var queryGeneration: UInt64 = 0
    private var searchTask: Task<Void, Never>?

    init(service: FolderSearchService) { self.service = service }

    func search(_ query: String, context: FolderSearchContext) {
        queryGeneration &+= 1
        let generation = queryGeneration
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { response = FolderSearchResponse(results: [], hasMore: false, configuredRootCount: response.configuredRootCount, isIndexing: false, hasIncompleteRoots: false); isSearching = false; return }
        if !isSearching { isSearching = true }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            let result = await service.search(query: query, context: context)
            guard !Task.isCancelled, generation == queryGeneration else { return }
            response = result
            isSearching = false
            searchTask = nil
        }
    }

    func cancel() { searchTask?.cancel(); searchTask = nil; isSearching = false }

    func reset() {
        cancel()
        queryGeneration &+= 1
        response = FolderSearchResponse(results: [], hasMore: false, configuredRootCount: response.configuredRootCount, isIndexing: false, hasIncompleteRoots: false)
    }
}
