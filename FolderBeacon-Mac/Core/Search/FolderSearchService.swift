import Foundation

actor FolderSearchService {
    private let index: FolderIndexCoordinator
    init(index: FolderIndexCoordinator) { self.index = index }

    func search(query: String, context: FolderSearchContext, limit: Int = 50) async -> FolderSearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let (indexed, roots, indexing, incomplete) = await index.search(trimmed, limit: limit)
        var values: [String: FolderSearchResult] = [:]
        func add(_ result: FolderSearchResult) { if var old = values[result.id] { old.sources.formUnion(result.sources); old.score = max(old.score, result.score); values[result.id] = old } else { values[result.id] = result } }
        if let direct = directPath(trimmed) { add(direct) }
        for (name, url) in context.finderFolders where matches(name: name, path: url.path, query: trimmed) { add(result(url: url, name: name, root: nil, source: .finder, score: 80)) }
        for (name, url) in context.favorites where matches(name: name, path: url.path, query: trimmed) { add(result(url: url, name: name, root: nil, source: .favorite, score: 100)) }
        for (name, url, date) in context.recent where matches(name: name, path: url.path, query: trimmed) { add(result(url: url, name: name, root: nil, source: .recent, score: max(1, Int(80 - Date.now.timeIntervalSince(date) / 86_400)))) }
        for (rootID, relative, name) in indexed where roots[rootID]?.isEnabled == true {
            guard let root = roots[rootID] else { continue }; let url = relative.isEmpty ? root.url : root.url.appendingPathComponent(relative, isDirectory: true)
            add(result(url: url, name: name, root: rootID, source: .localIndex, score: relevance(name: name, path: relative, query: trimmed)))
        }
        let sorted = values.values.sorted { $0.score == $1.score ? ($0.name, $0.url.path) < ($1.name, $1.url.path) : $0.score > $1.score }
        return FolderSearchResponse(results: Array(sorted.prefix(limit)), hasMore: sorted.count > limit, configuredRootCount: roots.count, isIndexing: indexing, hasIncompleteRoots: incomplete)
    }

    private func result(url: URL, name: String, root: UUID?, source: FolderSearchSource, score: Int) -> FolderSearchResult { FolderSearchResult(id: url.standardizedFileURL.path, url: url, name: name, rootID: root, sources: [source], availability: FileManager.default.fileExists(atPath: url.path) ? .available : .offline, score: score + relevance(name: name, path: url.path, query: "")) }
    private func directPath(_ query: String) -> FolderSearchResult? { guard query.hasPrefix("/") || query.hasPrefix("~/") else { return nil }; let path = NSString(string: query).expandingTildeInPath; var isDirectory = ObjCBool(false); guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }; let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL; return FolderSearchResult(id: url.path, url: url, name: url.lastPathComponent, rootID: nil, sources: [.directPath], availability: .available, score: 2_000) }
    private func matches(name: String, path: String, query: String) -> Bool { let tokens = FolderSearchNormalizer.tokens(for: query); return tokens.allSatisfy { FolderSearchNormalizer.normalize(name).contains($0) || FolderSearchNormalizer.normalize(path).contains($0) } }
    private func relevance(name: String, path: String, query: String) -> Int { let q = FolderSearchNormalizer.normalize(query); guard !q.isEmpty else { return 0 }; let n = FolderSearchNormalizer.normalize(name); let p = FolderSearchNormalizer.normalize(path); if n == q { return 1_000 }; if n.hasPrefix(q) { return 800 }; if n.contains(q) { return 600 }; return q.contains("/") && p.contains(q) ? 450 : 300 }
}
