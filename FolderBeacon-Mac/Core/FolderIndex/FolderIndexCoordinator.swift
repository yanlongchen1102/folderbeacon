import AppKit
import Combine
import Foundation

nonisolated private final class ScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
final class FolderIndexCoordinator: ObservableObject {
    @Published private(set) var rootSnapshots: [FolderIndexRootSnapshot] = []
    @Published private(set) var isStarted = false
    private let database: FolderIndexDatabase?
    private let searchDatabase: FolderIndexSearchDatabase?
    private let scanQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "com.folderbeacon.index-scan"; queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility; return queue
    }()
    private var generations: [UUID: UUID] = [:]
    private var scanTokens: [UUID: ScanCancellationToken] = [:]
    private let eventWatcher = FolderIndexEventWatcher()
    private var reconciliationDebounce: Task<Void, Never>?
    private var reconciliationInFlight = false
    private var availabilityRefreshTask: Task<Void, Never>?
    private var inaccessibleProtectedHomeFolders: Set<String> = []
    private var homePreflightTask: Task<[String], Never>?
    private let didRestoreHomeScopeKey = "FolderBeacon.didRestoreProtectedHomeFolders.v1"
    var diagnostic: ((String) -> Void)?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let identifier = Bundle.main.bundleIdentifier ?? "com.folderbeacon.app"
        let url = appSupport.appendingPathComponent(identifier, isDirectory: true).appendingPathComponent("FolderIndex/index.sqlite", isDirectory: false)
        do {
            database = try FolderIndexDatabase(databaseURL: url)
            searchDatabase = try? FolderIndexSearchDatabase(databaseURL: url)
        } catch {
            database = nil
            searchDatabase = nil
        }
        eventWatcher.onEvents = { [weak self] events in
            Task { @MainActor [weak self] in self?.receive(events) }
        }
    }

    func start() {
        guard !isStarted else { return }; isStarted = true
        guard let database else {
            diagnostic?("index.database.unavailable: unable to open the local index")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let stored = try await database.roots()
                let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                rootSnapshots = stored.map { root, date in FolderIndexRootSnapshot(root: root, availability: self.availability(of: root), state: root.isEnabled ? .notStarted : .paused, indexedFolderCount: 0, lastFullScanAt: date, detail: nil) }
                // Search across Home is opt in. Starting it here would trigger
                // Desktop/Documents/Downloads consent before the user asks to search them.
                if rootSnapshots.contains(where: { $0.root.isEnabled && $0.root.url.standardizedFileURL == home }) {
                    await preflightHomeFolders()
                }
                for snapshot in rootSnapshots where snapshot.root.isEnabled {
                    eventWatcher.start(root: snapshot.root)
                    let restoreHome = snapshot.root.url.standardizedFileURL == home && !UserDefaults.standard.bool(forKey: didRestoreHomeScopeKey)
                    snapshotCountAndStart(snapshot.root.id, force: restoreHome)
                }
                processNextPendingReconciliation()
                startAvailabilityRefresh()
            } catch { diagnostic?("index.database.recovered: \(error.localizedDescription)") }
        }
    }

    func stop() { scanTokens.values.forEach { $0.cancel() }; scanTokens.removeAll(); generations.removeAll(); reconciliationDebounce?.cancel(); availabilityRefreshTask?.cancel(); eventWatcher.stopAll(); scanQueue.cancelAllOperations() }

    func addRoot(_ url: URL) async throws -> SearchRoot {
        let normalized = url.standardizedFileURL
        guard (try? normalized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw FolderIndexError.notDirectory }
        if let existing = rootSnapshots.first(where: { path($0.root.url, contains: normalized) }) { throw FolderIndexError.contained(existing.root.displayName) }
        let children = rootSnapshots.filter { path(normalized, contains: $0.root.url) }
        if !children.isEmpty { throw FolderIndexError.containsExisting(children.map { $0.root.displayName }) }
        if normalized == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            await preflightHomeFolders()
        }
        let bookmark = try? normalized.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let resourceValues = try? normalized.resourceValues(forKeys: [.volumeUUIDStringKey])
        let volume = resourceValues?.volumeUUIDString
        let root = SearchRoot(id: UUID(), displayName: normalized.lastPathComponent.isEmpty ? normalized.path : normalized.lastPathComponent, lastKnownPath: normalized.path, bookmarkData: bookmark, volumeUUID: volume, isEnabled: true, includeHiddenFolders: false, addedAt: .now)
        guard let database else { throw FolderIndexError.databaseUnavailable }
        try await database.saveRoot(root)
        rootSnapshots.append(FolderIndexRootSnapshot(root: root, availability: availability(of: root), state: .notStarted, indexedFolderCount: 0, lastFullScanAt: nil, detail: nil))
        eventWatcher.start(root: root)
        startScan(root.id, force: true)
        return root
    }

    func removeRoot(_ id: UUID) async throws { guard let database else { throw FolderIndexError.databaseUnavailable }; scanTokens.removeValue(forKey: id)?.cancel(); generations[id] = UUID(); eventWatcher.stop(rootID: id); try await database.removeRoot(id); rootSnapshots.removeAll { $0.id == id }; diagnostic?("index.root.removed \(id)") }
    func pauseRoot(_ id: UUID) { update(id) { $0.root.isEnabled = false; $0.state = .paused }; scanTokens.removeValue(forKey: id)?.cancel(); generations[id] = UUID(); eventWatcher.stop(rootID: id); persist(id) }
    func resumeRoot(_ id: UUID) { update(id) { $0.root.isEnabled = true; $0.state = .notStarted }; persist(id); if let root = rootSnapshots.first(where: { $0.id == id })?.root { eventWatcher.start(root: root) }; startScan(id, force: false) }
    func rescanRoot(_ id: UUID) { startScan(id, force: true) }

    func refreshProtectedFolderAccess() {
        guard !inaccessibleProtectedHomeFolders.isEmpty,
              let homeRoot = rootSnapshots.first(where: { $0.root.isEnabled && $0.root.url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }) else { return }
        Task { [weak self] in
            guard let self else { return }
            await preflightHomeFolders()
            if inaccessibleProtectedHomeFolders.isEmpty { rescanRoot(homeRoot.id) }
        }
    }

    /// Home indexing starts only after the user enables it in Search Scope.
    func setHomeScopeEnabled(_ enabled: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if enabled {
            guard !rootSnapshots.contains(where: { $0.root.url.standardizedFileURL == home }) else { return }
            let children = rootSnapshots.filter { path(home, contains: $0.root.url) }
            Task { [weak self] in
                guard let self else { return }
                for child in children { try? await self.removeRoot(child.id) }
                _ = try? await self.addRoot(home)
            }
        } else if let existing = rootSnapshots.first(where: { $0.root.url.standardizedFileURL == home }) {
            Task { try? await removeRoot(existing.id) }
        }
    }

    func search(_ query: String, limit: Int) async -> ([(UUID, String, String)], [UUID: SearchRoot], Bool, Bool) {
        let tokens = FolderSearchNormalizer.tokens(for: query)
        let roots = Dictionary(uniqueKeysWithValues: rootSnapshots.map { ($0.id, $0.root) })
        let indexing = rootSnapshots.contains { $0.state == .scanning || $0.state == .updating }
        let incomplete = rootSnapshots.contains { $0.state == .incomplete || $0.availability != .available }
        guard !tokens.isEmpty else { return ([], roots, indexing, incomplete) }
        guard !Task.isCancelled else { return ([], roots, indexing, incomplete) }
        guard let database else { return ([], roots, indexing, true) }
        do {
            let matches: [(UUID, String, String)]
            if let searchDatabase { matches = try await searchDatabase.search(tokens: tokens, limit: limit + 1) }
            else { matches = try await database.search(tokens: tokens, limit: limit + 1) }
            return (matches, roots, indexing, incomplete)
        }
        catch is CancellationError { return ([], roots, indexing, incomplete) }
        catch { diagnostic?("search.local.failed: \(error.localizedDescription)"); return ([], roots, indexing, true) }
    }

    private func snapshotCountAndStart(_ id: UUID, force: Bool) {
        Task { [weak self] in
            guard let self, let index = rootSnapshots.firstIndex(where: { $0.id == id }) else { return }
            guard let database else { return }
            rootSnapshots[index].indexedFolderCount = (try? await database.folderCount(rootID: id)) ?? 0
            if force || rootSnapshots[index].indexedFolderCount == 0 { startScan(id, force: force) }
            else { rootSnapshots[index].state = .ready }
        }
    }

    private func startScan(_ id: UUID, force: Bool) {
        guard let snapshot = rootSnapshots.first(where: { $0.id == id }), snapshot.root.isEnabled else { return }
        let available = availability(of: snapshot.root)
        guard available == .available else { update(id) { $0.availability = available; $0.state = .incomplete; $0.detail = "Search directory is currently unavailable." }; return }
        let generation = UUID(); generations[id] = generation
        scanTokens.removeValue(forKey: id)?.cancel()
        let token = ScanCancellationToken(); scanTokens[id] = token
        update(id) { $0.availability = .available; $0.state = .scanning; $0.detail = nil }
        guard let database else { return }
        let root = snapshot.root; let scanner = FolderIndexScanner(); let queue = scanQueue
        diagnostic?("index.scan.started \(id)")
        queue.addOperation { [weak self] in
            let stamp = Date.now.timeIntervalSince1970
            // OperationQueue considers an operation finished when its closure returns.
            // Keep that boundary aligned with the async database/scanner work so scans remain serialized.
            let completion = DispatchSemaphore(value: 0)
            let cancelled: @Sendable () -> Bool = { token.isCancelled }
            Task {
                defer { completion.signal() }
                do {
                    try await database.beginScan(rootID: id, stamp: stamp)
                    try await scanner.scan(root: root, isCancelled: cancelled, consume: { batch in
                        try? await database.upsert(batch, rootID: id, stamp: stamp)
                    }, unreadable: { path in
                        try? await database.preserveUnreadableSubtree(rootID: id, relativePath: path, stamp: stamp)
                    })
                    guard !cancelled() else { throw CancellationError() }
                    try await database.finishScan(rootID: id, stamp: stamp)
                    let count = try await database.folderCount(rootID: id)
                    await MainActor.run { [weak self] in
                        guard let self, self.generations[id] == generation else { return }
                        self.update(id) { $0.state = .ready; $0.indexedFolderCount = count; $0.lastFullScanAt = Date(timeIntervalSince1970: stamp) }
                        if root.url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
                           self.inaccessibleProtectedHomeFolders.isEmpty {
                            UserDefaults.standard.set(true, forKey: self.didRestoreHomeScopeKey)
                        }
                        self.diagnostic?("index.scan.finished \(id), \(count) folders")
                    }
                } catch is CancellationError { await MainActor.run { [weak self] in self?.diagnostic?("index.scan.cancelled \(id)") } }
                catch { await MainActor.run { [weak self] in guard self?.generations[id] == generation else { return }; self?.update(id) { $0.state = .incomplete; $0.detail = error.localizedDescription }; self?.diagnostic?("index.scan.incomplete \(id): \(error.localizedDescription)") } }
            }
            completion.wait()
        }
    }

    private func receive(_ events: [FolderIndexEventWatcher.Event]) {
        guard let database else { return }
        Task { [weak self] in
            for event in events {
                guard let root = self?.rootSnapshots.first(where: { $0.id == event.rootID })?.root, root.isEnabled else { continue }
                let changedURL = URL(fileURLWithPath: event.path)
                let target = event.mustScanSubdirectories ? root.url : changedURL.deletingLastPathComponent()
                let relative = self?.relativePath(target, under: root.url) ?? ""
                // Persist the task before any scan starts: a crash cannot lose this change.
                try? await database.enqueueReconciliation(rootID: event.rootID, relativePath: relative, recursive: event.mustScanSubdirectories, reason: "fsevents:\(event.eventID)")
            }
            await MainActor.run { [weak self] in self?.schedulePendingReconciliation() }
        }
    }

    private func schedulePendingReconciliation() {
        reconciliationDebounce?.cancel()
        reconciliationDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.processNextPendingReconciliation()
        }
    }

    private func processNextPendingReconciliation() {
        guard !reconciliationInFlight, let database else { return }
        reconciliationInFlight = true
        Task { [weak self] in
            let pending = (try? await database.pendingReconciliations()) ?? []
            await MainActor.run {
                guard let self else { return }
                guard let item = pending.first(where: { item in self.rootSnapshots.contains(where: { snapshot in snapshot.id == item.0 && snapshot.root.isEnabled }) }) else { self.reconciliationInFlight = false; return }
                self.startReconciliation(rootID: item.0, relativePath: item.1, database: database)
            }
        }
    }

    private func startReconciliation(rootID: UUID, relativePath: String, database: FolderIndexDatabase) {
        guard let snapshot = rootSnapshots.first(where: { $0.id == rootID }), availability(of: snapshot.root) == .available else {
            reconciliationInFlight = false
            update(rootID) { $0.availability = .offline; $0.state = .incomplete; $0.detail = "Search directory is offline; its indexed folders were kept." }
            return
        }
        let root = snapshot.root; let scanner = FolderIndexScanner(); let queue = scanQueue; let generation = UUID(); generations[rootID] = generation
        scanTokens.removeValue(forKey: rootID)?.cancel()
        let token = ScanCancellationToken(); scanTokens[rootID] = token
        update(rootID) { $0.state = .updating; $0.detail = nil }
        queue.addOperation { [weak self] in
            let stamp = Date.now.timeIntervalSince1970; let completion = DispatchSemaphore(value: 0)
            let cancelled: @Sendable () -> Bool = { token.isCancelled }
            Task {
                defer { completion.signal() }
                do {
                    try await database.beginReconciliation(rootID: rootID, relativePath: relativePath, stamp: stamp)
                    try await scanner.scan(root: root, startingAt: relativePath, isCancelled: cancelled, consume: { batch in
                        try? await database.upsert(batch, rootID: rootID, stamp: stamp)
                    }, unreadable: { path in
                        try? await database.preserveUnreadableSubtree(rootID: rootID, relativePath: path, stamp: stamp)
                    })
                    guard !cancelled() else { throw CancellationError() }
                    try await database.finishReconciliation(rootID: rootID, relativePath: relativePath, stamp: stamp)
                    try await database.completeReconciliation(rootID: rootID, relativePath: relativePath)
                    let count = try await database.folderCount(rootID: rootID)
                    await MainActor.run { [weak self] in
                        guard let self, self.generations[rootID] == generation else { return }
                        self.update(rootID) { $0.state = .ready; $0.indexedFolderCount = count }
                        self.diagnostic?("index.reconcile.finished \(rootID), \(relativePath)")
                        self.reconciliationInFlight = false
                        self.processNextPendingReconciliation()
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.reconciliationInFlight = false
                        self?.update(rootID) { $0.state = .incomplete; $0.detail = error.localizedDescription }
                        self?.schedulePendingReconciliation()
                    }
                }
            }
            completion.wait()
        }
    }

    private func persist(_ id: UUID) { guard let database, let root = rootSnapshots.first(where: { $0.id == id })?.root else { return }; Task { try? await database.saveRoot(root) } }

    private func preflightHomeFolders() async {
        if let homePreflightTask {
            inaccessibleProtectedHomeFolders = Set(await homePreflightTask.value)
            return
        }
        diagnostic?("index.permissions.preflight.started")
        let task = Task.detached(priority: .userInitiated) {
            Self.probeProtectedHomeFolders()
        }
        homePreflightTask = task
        let inaccessible = await task.value
        homePreflightTask = nil
        inaccessibleProtectedHomeFolders = Set(inaccessible)
        diagnostic?("index.permissions.preflight.finished; inaccessible: \(inaccessible.joined(separator: ", "))")
    }

    nonisolated private static func probeProtectedHomeFolders() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let manager = FileManager.default
        var inaccessible: [String] = []
        for name in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"] {
            let folder = home.appendingPathComponent(name, isDirectory: true)
            // Enumerating one level triggers macOS's first-use consent before
            // the much slower recursive index reaches this folder.
            do { _ = try manager.contentsOfDirectory(atPath: folder.path) }
            catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { continue }
                inaccessible.append(name)
            }
        }
        return inaccessible
    }

    private func update(_ id: UUID, _ body: (inout FolderIndexRootSnapshot) -> Void) { guard let index = rootSnapshots.firstIndex(where: { $0.id == id }) else { return }; body(&rootSnapshots[index]) }
    private func availability(of url: URL) -> SearchRootAvailability { var directory: ObjCBool = false; if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) { return directory.boolValue ? .available : .missing }; return .missing }
    private func availability(of root: SearchRoot) -> SearchRootAvailability { Self.checkAvailability(of: root) }
    private func relativePath(_ url: URL, under root: URL) -> String { let rootPath = root.standardizedFileURL.path; let path = url.standardizedFileURL.path; guard path == rootPath || path.hasPrefix(rootPath + "/") else { return "" }; return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private func startAvailabilityRefresh() {
        availabilityRefreshTask?.cancel()
        availabilityRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                let roots = self.rootSnapshots.filter { $0.root.isEnabled }.map(\.root)
                let availability = await Task.detached(priority: .utility) {
                    roots.map { ($0.id, Self.checkAvailability(of: $0)) }
                }.value
                guard !Task.isCancelled else { return }
                for (id, current) in availability {
                    guard let snapshot = self.rootSnapshots.first(where: { $0.id == id && $0.root.isEnabled }) else { continue }
                    if current == .available && snapshot.availability != .available {
                        self.update(snapshot.id) { $0.availability = .available; $0.state = .updating; $0.detail = nil }
                        self.eventWatcher.start(root: snapshot.root)
                        self.rescanRoot(snapshot.id)
                    } else if current != .available && snapshot.availability == .available {
                        self.eventWatcher.stop(rootID: snapshot.id)
                        self.update(snapshot.id) { $0.availability = current; $0.state = .incomplete; $0.detail = current == .offline ? "Search directory is offline; its indexed folders were kept." : "Search directory is unavailable." }
                    }
                }
            }
        }
    }
    nonisolated private static func checkAvailability(of root: SearchRoot) -> SearchRootAvailability {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.url.path, isDirectory: &directory) {
            return directory.boolValue ? .available : .missing
        }
        guard let expectedVolume = root.volumeUUID else { return .missing }
        let mounted = (try? FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: [.skipHiddenVolumes])) ?? []
        return mounted.contains { (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == expectedVolume } ? .missing : .offline
    }
    private func path(_ parent: URL, contains child: URL) -> Bool { let parentParts = parent.standardizedFileURL.pathComponents; let childParts = child.standardizedFileURL.pathComponents; return parentParts.count <= childParts.count && zip(parentParts, childParts).allSatisfy(==) }
}

enum FolderIndexError: LocalizedError { case notDirectory, databaseUnavailable, contained(String), containsExisting([String]); var errorDescription: String? { switch self { case .notDirectory: return "Choose a folder."; case .databaseUnavailable: return "The local folder index could not be opened."; case .contained(let name): return "This folder is already contained in \(name)."; case .containsExisting(let names): return "This folder contains existing search ranges: \(names.joined(separator: ", "))." } } }
