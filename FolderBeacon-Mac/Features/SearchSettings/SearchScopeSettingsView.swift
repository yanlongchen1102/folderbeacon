import SwiftUI

struct SearchScopeSettingsView: View {
    @ObservedObject var state: AppState
    @AppStorage("FolderBeacon.enableSpotlightSupplement") private var enableSpotlightSupplement = false
    @State private var includesHome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Search folders in your Home folder and any directories you add."))
                .font(.title3.weight(.semibold))
            Text(L10n.string("FolderBeacon builds its own local index. It excludes Library, Trash, and common generated folders by default; Spotlight is not required."))
                .foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { includesHome }, set: { value in includesHome = value; state.folderIndex.setHomeScopeEnabled(value) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Include folders in Home"))
                    Text("\(FileManager.default.homeDirectoryForCurrentUser.path) · excluding ~/Library and ~/.Trash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            if state.folderIndex.rootSnapshots.isEmpty {
                ContentUnavailableView(L10n.string("No Search Folders"), systemImage: "folder.badge.plus", description: Text(L10n.string("Add a directory to search its folders.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(scopeRows, id: \.id) { (row: ScopeRow) in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                                Text(row.name).fontWeight(.medium)
                                Spacer()
                                Text(row.status).font(.caption).foregroundStyle(row.isReady ? Color.secondary : Color.orange)
                            }
                            Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text("\(row.count) folders\(row.lastScan.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")").font(.caption2).foregroundStyle(.secondary)
                            if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.orange) }
                            HStack {
                                Button(row.isPaused ? L10n.string("Resume") : L10n.string("Pause")) { row.isPaused ? state.folderIndex.resumeRoot(row.id) : state.folderIndex.pauseRoot(row.id) }
                                Button(L10n.string("Rescan")) { state.folderIndex.rescanRoot(row.id) }
                                Button(L10n.string("Remove"), role: .destructive) { Task { try? await state.folderIndex.removeRoot(row.id) } }
                            }.controlSize(.small)
                        }.padding(.vertical, 4)
                    }
                }.listStyle(.inset)
            }
            HStack { Button { state.chooseSearchRoot() } label: { Label(L10n.string("Add Folder"), systemImage: "plus") }; Spacer(); Toggle(L10n.string("Use Spotlight as a supplement"), isOn: $enableSpotlightSupplement).disabled(true) }
            Text(L10n.string("Spotlight supplementation is planned and remains off by default; local indexing is the primary search source.")) .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .onAppear { syncHomeScope() }
        .onChange(of: state.folderIndex.rootSnapshots.count) { _, _ in syncHomeScope() }
    }

    private func status(_ snapshot: FolderIndexRootSnapshot) -> String {
        switch snapshot.state { case .scanning: return L10n.string("Building index"); case .ready: return L10n.string("Ready"); case .paused: return L10n.string("Paused"); case .incomplete: return L10n.string("Incomplete"); case .failed: return L10n.string("Failed"); case .updating: return L10n.string("Updating"); case .notStarted: return L10n.string("Waiting") }
    }

    private var scopeRows: [ScopeRow] {
        state.folderIndex.rootSnapshots.map { snapshot in
            ScopeRow(id: snapshot.id, name: snapshot.root.displayName, path: snapshot.root.lastKnownPath, status: status(snapshot), isReady: snapshot.state == .ready, isPaused: snapshot.state == .paused, count: snapshot.indexedFolderCount, lastScan: snapshot.lastFullScanAt, detail: snapshot.detail)
        }
    }

    private func syncHomeScope() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        includesHome = state.folderIndex.rootSnapshots.contains { $0.root.url.standardizedFileURL == home }
    }

    nonisolated private struct ScopeRow: Identifiable {
        let id: UUID
        let name: String
        let path: String
        let status: String
        let isReady: Bool
        let isPaused: Bool
        let count: Int
        let lastScan: Date?
        let detail: String?
    }
}
