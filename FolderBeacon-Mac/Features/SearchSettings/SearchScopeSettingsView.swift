import SwiftUI

struct SearchScopeSettingsView: View {
    @ObservedObject var state: AppState
    @State private var includesHome = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string("Search Scope")).font(.title2.weight(.semibold))
                    Text(L10n.string("Choose where FolderBeacon looks for folders. Search happens locally and does not depend on Spotlight."))
                        .font(.callout).foregroundStyle(.secondary)
                }

                GroupBox {
                    Toggle(isOn: Binding(get: { includesHome }, set: { value in
                        includesHome = value
                        state.folderIndex.setHomeScopeEnabled(value)
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.string("Index folders in Home")).fontWeight(.medium)
                            Text(L10n.string("Includes your usual folders and custom workspaces. Library, Trash, and common generated folders are excluded."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }

                HStack {
                    Text(L10n.string("Indexed Locations")).font(.headline)
                    Spacer()
                    Button { state.chooseSearchRoot() } label: {
                        Label(L10n.string("Add Folder"), systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                GroupBox {
                    if scopeRows.isEmpty {
                        ContentUnavailableView(L10n.string("No Search Folders"), systemImage: "folder.badge.plus", description: Text(L10n.string("Add a folder to make its subfolders searchable.")))
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(scopeRows, id: \.id) { (row: ScopeRow) in
                                scopeRow(row)
                                if row.id != scopeRows.last?.id { Divider().padding(.leading, 36) }
                            }
                        }
                    }
                }

                Text(L10n.string("Changes are indexed in the background. You can pause a location without removing its saved index."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onAppear { syncHomeScope() }
        .onChange(of: state.folderIndex.rootSnapshots.count) { _, _ in syncHomeScope() }
    }

    private func scopeRow(_ row: ScopeRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).fontWeight(.medium).lineLimit(1)
                Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Label(row.status, systemImage: row.isReady ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(row.isReady ? Color.green : Color.orange)
                Text(L10n.format("%d folders indexed", row.count)).font(.caption2).foregroundStyle(.secondary)
            }
            Menu {
                Button(row.isPaused ? L10n.string("Resume Indexing") : L10n.string("Pause Indexing")) { row.isPaused ? state.folderIndex.resumeRoot(row.id) : state.folderIndex.pauseRoot(row.id) }
                Button(L10n.string("Rescan Now")) { state.folderIndex.rescanRoot(row.id) }
                Divider()
                Button(L10n.string("Remove Search Folder"), role: .destructive) { Task { try? await state.folderIndex.removeRoot(row.id) } }
            } label: {
                Image(systemName: "ellipsis.circle").imageScale(.large)
            }
            .menuStyle(.borderlessButton).frame(width: 28)
        }
        .padding(.vertical, 9).padding(.horizontal, 4)
        .help(row.detail ?? row.lastScan.map { L10n.format("Last full scan: %@", $0.formatted(date: .abbreviated, time: .shortened)) } ?? "")
    }

    private func status(_ snapshot: FolderIndexRootSnapshot) -> String {
        switch snapshot.state {
        case .scanning: return L10n.string("Building Index")
        case .ready: return L10n.string("Ready")
        case .paused: return L10n.string("Paused")
        case .incomplete: return L10n.string("Needs Attention")
        case .failed: return L10n.string("Failed")
        case .updating: return L10n.string("Updating")
        case .notStarted: return L10n.string("Waiting")
        }
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
        let id: UUID; let name: String; let path: String; let status: String
        let isReady: Bool; let isPaused: Bool; let count: Int; let lastScan: Date?; let detail: String?
    }
}
