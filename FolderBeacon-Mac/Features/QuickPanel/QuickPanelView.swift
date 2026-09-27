import SwiftUI

struct QuickPanelView: View {
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject var state: AppState
    @ObservedObject var projects: ProjectFolderStore
    var movePanel: (CGSize) -> Void
    @AppStorage("PathPilot.showFinderWindows") private var showFinderWindows = true
    @AppStorage("PathPilot.showRecentFolders") private var showRecentFolders = true
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool
    @StateObject private var searchModel: QuickPanelSearchModel

    init(state: AppState, projects: ProjectFolderStore, movePanel: @escaping (CGSize) -> Void) {
        self.state = state
        self.projects = projects
        self.movePanel = movePanel
        _searchModel = StateObject(wrappedValue: QuickPanelSearchModel(service: state.folderSearch))
    }

    private struct FolderResult: Identifiable, Hashable {
        let id: String; let name: String; let url: URL; let kind: Kind
        enum Kind { case path, current, finder, favorite, recent, localIndex }
    }

    private var searchableResults: [FolderResult] {
        var result: [FolderResult] = []
        func append(_ name: String, _ url: URL, _ kind: FolderResult.Kind) {
            guard !result.contains(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) else { return }
            result.append(FolderResult(id: "\(kind)-\(url.path)", name: name, url: url, kind: kind))
        }
        if let first = state.finderFolders.first { append(first.windowName, first.url, .current) }
        if showFinderWindows { state.finderFolders.forEach { append($0.windowName, $0.url, .finder) } }
        projects.folders.forEach { append($0.name, $0.url, .favorite) }
        if showRecentFolders { state.recentStore.entries.prefix(5).forEach { append($0.displayName, URL(fileURLWithPath: $0.path), .recent) } }
        return result
    }

    private var defaultResults: [FolderResult] {
        // Open Finder windows are the strongest context signal, followed by
        // explicit favorites and then recently used folders.
        searchableResults.filter { $0.kind == .current || $0.kind == .finder || $0.kind == .favorite || $0.kind == .recent }
    }

    private var results: [FolderResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return defaultResults }
        return searchModel.response.results.prefix(50).map { result in
            let kind: FolderResult.Kind
            if result.sources.contains(.directPath) { kind = .path }
            else if result.sources.contains(.favorite) { kind = .favorite }
            else if result.sources.contains(.recent) { kind = .recent }
            else if result.sources.contains(.finder) { kind = .finder }
            else { kind = .localIndex }
            return FolderResult(id: result.id, name: result.name, url: result.url, kind: kind)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 8)
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { movePanel($0.translation) }
                .onEnded { _ in state.finishQuickPanelDrag() })

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 15, weight: .medium))
                TextField(L10n.string("Search folders or paths…"), text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .font(.system(size: 15, weight: .medium))
                    .onSubmit { openSelection() }
                    // TextField normally consumes arrow keys to move its text
                    // cursor. FolderBeacon uses them to navigate its result list.
                    .onKeyPress(.upArrow) { moveSelection(.up); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(.down); return .handled }
                    .onKeyPress(.escape) { state.dismissQuickPanel(); return .handled }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 12).padding(.bottom, 9)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { searchFocused = true })

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            ScrollView {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contextBrowser
                } else if searchModel.isSearching && results.isEmpty {
                    ProgressView(L10n.string("Searching folders…")).controlSize(.small).padding(.top, 32)
                } else if results.isEmpty {
                    ContentUnavailableView(searchModel.response.configuredRootCount == 0 ? L10n.string("Add a search folder to find folders inside it.") : L10n.format("No folders found for %@", query), systemImage: "magnifyingglass", description: Text(L10n.string("Try another folder name or path.")))
                        .padding(.top, 52)
                } else {
                    VStack(spacing: 0) {
                        resultRows(results)
                        if searchModel.response.isIndexing { Text(L10n.string("Building folder index…")) .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6) }
                    }
                }
            }
        }
        .frame(width: 460, height: 270)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .preferredColorScheme(.dark)
        .onAppear {
            selectedIndex = 0
            searchFocused = state.quickPanelShouldFocusSearch
        }
        .onChange(of: state.quickPanelSearchFocusGeneration) { _, _ in
            searchFocused = state.quickPanelShouldFocusSearch
        }
        .onChange(of: query) { _, value in
            state.recordSearchUsage(isEmpty: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            selectedIndex = 0
            searchModel.search(value, context: searchContext)
        }
        .onDisappear { searchModel.cancel() }
        .onMoveCommand { direction in moveSelection(direction) }
        .onExitCommand { state.dismissQuickPanel() }
    }

    private var searchContext: FolderSearchContext {
        FolderSearchContext(
            finderFolders: state.finderFolders.map { ($0.windowName, $0.url) },
            favorites: projects.folders.map { ($0.name, $0.url) },
            recent: state.recentStore.entries.map { ($0.displayName, URL(fileURLWithPath: $0.path), $0.lastUsedAt) }
        )
    }

    @ViewBuilder private var contextBrowser: some View {
        if defaultResults.isEmpty {
            ContentUnavailableView(L10n.string("No folders yet"), systemImage: "folder", description: Text(L10n.string("Start typing to find a folder, or add frequently used folders to Favorites.")))
                .padding(.top, 28)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                section(L10n.string("Finder Windows"), rows: defaultResults.filter { $0.kind == .current || $0.kind == .finder })
                section(L10n.string("Recent"), rows: defaultResults.filter { $0.kind == .recent })
                section(L10n.string("Favorites"), rows: defaultResults.filter { $0.kind == .favorite })
            }.padding(.vertical, 6)
        }
    }

    @ViewBuilder private func section(_ title: String, rows: [FolderResult]) -> some View {
        if !rows.isEmpty {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 8)
            resultRows(rows)
        }
    }

    private func resultRows(_ rows: [FolderResult]) -> some View {
        ForEach(rows) { row in
            let index = results.firstIndex(of: row) ?? 0
            Button { selectedIndex = index; openSelection() } label: {
                HStack(spacing: 10) {
                    Image(systemName: row.kind == .favorite ? "star.fill" : "folder.fill").foregroundStyle(row.kind == .favorite ? .yellow : .accentColor).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).foregroundStyle(.primary).lineLimit(1)
                        Text(row.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }.padding(.horizontal, 14).padding(.vertical, 7).contentShape(Rectangle())
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.32) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain).padding(.horizontal, 8)
            .contextMenu { Button(L10n.string("Open in Finder")) { state.capturePanelEvent(.openInFinder); NSWorkspace.shared.open(row.url) }; Button(L10n.string("Copy Path")) { state.capturePanelEvent(.copyPath); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.url.path, forType: .string) } }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !results.isEmpty else { return }
        switch direction { case .up: selectedIndex = max(0, selectedIndex - 1); case .down: selectedIndex = min(results.count - 1, selectedIndex + 1); default: break }
    }
    private func openSelection() { guard results.indices.contains(selectedIndex) else { return }; state.navigateFromQuickPanel(to: results[selectedIndex].url) }

    private func searchScore(_ result: FolderResult, query: String) -> Int {
        let name = result.name.lowercased()
        var score: Int
        if name == query { score = 1_000 }
        else if name.hasPrefix(query) { score = 700 }
        else { score = 400 }

        switch result.kind {
        case .path: score += 2_000
        case .favorite: score += 100
        case .recent: score += 70
        case .current: score += 90
        case .finder: score += 80
        case .localIndex: break
        }
        return score
    }

    private func directPathResult(_ value: String) -> FolderResult? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return FolderResult(id: "path-\(url.path)", name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, url: url, kind: .path)
    }
}
