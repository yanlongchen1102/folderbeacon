import Combine
import Foundation
import SwiftUI

@MainActor
final class ProjectFolderStore: ObservableObject {
    @Published private(set) var folders: [ProjectFolder]
    private let storageKey = "PathPilot.projectFolders.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ProjectFolder].self, from: data) {
            folders = saved
        } else {
            folders = []
            save()
        }
    }

    func update(name: String, url: URL) {
        let normalizedURL = url.standardizedFileURL
        if let index = folders.firstIndex(where: { $0.name == name }) {
            folders[index].path = normalizedURL.path
        } else {
            folders.append(ProjectFolder(id: UUID(), name: name, path: normalizedURL.path))
        }
        save()
    }

    func add(url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard !folders.contains(where: { $0.path == normalizedURL.path }) else { return }
        folders.append(ProjectFolder(id: UUID(), name: normalizedURL.lastPathComponent, path: normalizedURL.path))
        save()
    }

    func rename(id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders[index].name = trimmed
        save()
    }

    func remove(id: UUID) {
        folders.removeAll { $0.id == id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        folders.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
