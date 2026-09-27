import Foundation
import Combine

@MainActor
final class RecentFolderStore: ObservableObject {
    @Published private(set) var entries: [RecentFolder]
    private let storageKey = "PathPilot.recentFolders.v1"

    init() {
        let data = UserDefaults.standard.data(forKey: storageKey)
        entries = (try? data.flatMap { try JSONDecoder().decode([RecentFolder].self, from: $0) }) ?? []
        entries.sort { $0.lastUsedAt > $1.lastUsedAt }
    }

    func record(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        if let index = entries.firstIndex(where: { $0.path == path }) {
            entries[index].lastUsedAt = .now
            entries[index].useCount += 1
        } else {
            entries.append(RecentFolder(path: path, displayName: folder.lastPathComponent, lastUsedAt: .now, useCount: 1))
        }
        entries.sort { $0.lastUsedAt > $1.lastUsedAt }
        entries = Array(entries.prefix(50))
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
