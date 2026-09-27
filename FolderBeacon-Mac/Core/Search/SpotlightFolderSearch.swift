import Foundation
import Combine

struct SpotlightFolder: Identifiable, Hashable {
    let url: URL
    let name: String
    var id: String { url.standardizedFileURL.path }
}

@MainActor
final class SpotlightFolderSearch: NSObject, ObservableObject {
    @Published private(set) var results: [SpotlightFolder] = []
    @Published private(set) var isSearching = false

    private var debounceTask: Task<Void, Never>?
    private var activeQuery: NSMetadataQuery?
    private var notificationTokens: [NSObjectProtocol] = []
    var diagnostic: ((String) -> Void)?

    func search(_ text: String, supplementalDirectories: [URL]) {
        debounceTask?.cancel()
        stopActiveQuery()

        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }

        results = []
        isSearching = true
        diagnostic?("Spotlight search queued: \(query)")
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            self?.startSpotlightSearch(query, supplementalDirectories: supplementalDirectories)
        }
    }

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        stopActiveQuery()
        results = []
        isSearching = false
    }

    private func startSpotlightSearch(_ text: String, supplementalDirectories: [URL]) {
        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
        metadataQuery.predicate = NSPredicate(
            format: "%K == %@ AND %K CONTAINS[cd] %@",
            NSMetadataItemContentTypeKey, "public.folder", NSMetadataItemFSNameKey, text
        )
        activeQuery = metadataQuery
        diagnostic?("Spotlight search starting: \(text); Finder supplement roots: \(supplementalDirectories.count)")

        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: metadataQuery, queue: .main) { [weak self, weak metadataQuery] _ in
                guard let self, let metadataQuery else { return }
                self.receive(metadataQuery, query: text, supplementalDirectories: supplementalDirectories)
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: metadataQuery, queue: .main) { [weak self, weak metadataQuery] _ in
                guard let self, let metadataQuery else { return }
                self.receive(metadataQuery, query: text, supplementalDirectories: supplementalDirectories)
            }
        ]
        let started = metadataQuery.start()
        diagnostic?("Spotlight query \(started ? "started" : "failed to start"): \(text)")
        if !started {
            stopActiveQuery()
            isSearching = false
        }
    }

    private func receive(_ metadataQuery: NSMetadataQuery, query: String, supplementalDirectories: [URL]) {
        guard metadataQuery === activeQuery else { return }
        metadataQuery.disableUpdates()
        let rawCount = metadataQuery.results.count
        var metadataItems = 0
        var missingLocation = 0
        let spotlightFolders = metadataQuery.results.prefix(64).compactMap { item -> SpotlightFolder? in
            guard let metadataItem = item as? NSMetadataItem else { return nil }
            metadataItems += 1

            let urlValue = metadataItem.value(forAttribute: NSMetadataItemURLKey)
            let pathValue = metadataItem.value(forAttribute: NSMetadataItemPathKey) as? String
            let url = (urlValue as? URL) ?? pathValue.map { URL(fileURLWithPath: $0) }
            guard let url else {
                missingLocation += 1
                return nil
            }
            let name = (metadataItem.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent
            return SpotlightFolder(url: url.standardizedFileURL, name: name)
        }
        metadataQuery.enableUpdates()

        let supplemental = immediateChildFolders(of: supplementalDirectories)
        results = unique(spotlightFolders + supplemental).filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.url.path.localizedCaseInsensitiveContains(query)
        }
        diagnostic?("Spotlight update for \(query): raw \(rawCount), metadata \(metadataItems), missing location \(missingLocation), folders \(spotlightFolders.count), Finder supplement \(supplemental.count), merged \(results.count)")
        isSearching = false
    }

    private func immediateChildFolders(of directories: [URL]) -> [SpotlightFolder] {
        directories.flatMap { directory in
            let urls: [URL] = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            return urls.prefix(100).compactMap { url -> SpotlightFolder? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                return SpotlightFolder(url: url.standardizedFileURL, name: url.lastPathComponent)
            }
        }
    }

    private func unique(_ folders: [SpotlightFolder]) -> [SpotlightFolder] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0.id).inserted }
    }

    private func stopActiveQuery() {
        activeQuery?.stop()
        activeQuery = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
    }

    deinit {
        activeQuery?.stop()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }
}
