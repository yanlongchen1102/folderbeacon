import AppKit
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var isAccessibilityTrusted = AccessibilityPermissionManager.isTrusted
    @Published var timing = NavigationTiming()
    @Published private(set) var targetContext: TargetApplicationContext?
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var finderFolders: [FinderWindowFolder] = []
    @Published private(set) var finderLookupStatus = "Not checked yet"
    @Published private(set) var automationTestStatus = "Not checked yet"
    @Published private(set) var finderPermissionMessage = ""
    @Published private(set) var isFileDialogActive = false
    @Published private(set) var fileDialogTitle = ""
    @Published private(set) var isFinderAccessAvailable = false
    @Published private(set) var isFinderPermissionChecked = false
    @Published var requestedSettingsPage: SettingsPage?
    @Published private(set) var globalShortcut = GlobalShortcut.load()
    @Published private(set) var globalShortcutStatus = ""
    @Published private(set) var quickPanelSearchFocusGeneration = 0
    @Published private(set) var quickPanelSessionGeneration = 0
    private(set) var quickPanelShouldFocusSearch = false

    let targetTracker = TargetAppTracker()
    let recentStore = RecentFolderStore()
    let projectStore = ProjectFolderStore()
    let folderIndex = FolderIndexCoordinator()
    lazy var folderSearch = FolderSearchService(index: folderIndex)
    private lazy var navigator = FilePanelNavigator(diagnostics: log)
    private lazy var quickPanel = QuickPanelController(state: self)
    private lazy var hotkey = GlobalHotkeyManager(
        handler: { [weak self] in self?.showQuickPanel() },
        registrationResult: { [weak self] message in
            self?.globalShortcutStatus = message
            self?.log(message)
        }
    )
    private lazy var filePanelDetector = FilePanelDetector()
    private var isShowingAutomatically = false
    private var activeFilePanelFrame: CGRect?
    private var activeFilePanelSession: FilePanelContext?
    private var navigationTask: Task<Void, Never>?
    private var finderLookupGeneration = UUID()
    private var hasCountedSearch = false
    // Snapshot the host app for the panel session; focusing our panel must not change it.
    private var panelUseApp = "unknown"

    func capturePanelEvent(_ event: UsageAnalytics.Event) {
        UsageAnalytics.capture(event, useApp: panelUseApp)
    }

    func recordSearchUsage(isEmpty: Bool) {
        if isEmpty { hasCountedSearch = false; return }
        guard !hasCountedSearch else { return }
        hasCountedSearch = true
        capturePanelEvent(.searchUsed)
    }

    func resetSearchUsage() { hasCountedSearch = false }

    var targetDescription: String {
        guard let targetContext else { return "No app captured" }
        return "\(targetContext.name) (pid \(targetContext.pid))"
    }

    var diagnosticsText: String { diagnostics.joined(separator: "\n") }
    var panelContextTitle: String {
        guard isFileDialogActive, let targetContext else { return "Open in Finder" }
        let action = fileDialogTitle.isEmpty ? "File Dialog" : fileDialogTitle
        return "\(targetContext.name) · \(action)"
    }

    func start() {
        log("FolderBeacon started")
        log("Runtime bundle identifier: \(Bundle.main.bundleIdentifier ?? "missing")")
        log("Runtime bundle URL: \(Bundle.main.bundleURL.path)")
        log("NSAppleEventsUsageDescription: \(Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String ?? "missing")")
        refreshAccessibilityState()
        refreshFinderPermission()
        _ = hotkey.start(shortcut: globalShortcut)
        configureFilePanelDetector()
        filePanelDetector.start()
        folderIndex.diagnostic = { [weak self] in self?.log($0) }
        folderIndex.start()
    }

    func stop() {
        navigationTask?.cancel()
        hotkey.stop()
        filePanelDetector.stop()
        folderIndex.stop()
    }

    func openAccessibilitySettings() {
        AccessibilityPermissionManager.openSettings()
    }

    func refreshAccessibilityState() {
        let trusted = AccessibilityPermissionManager.isTrusted
        guard isAccessibilityTrusted != trusted else { return }
        isAccessibilityTrusted = trusted
        if trusted {
            filePanelDetector.start()
            log("Accessibility permission enabled; automatic detection started")
        } else {
            navigationTask?.cancel()
            filePanelDetector.stop()
            clearFilePanelSession(hideAutomaticPanel: true)
            log("Accessibility permission unavailable; automatic detection stopped")
        }
    }

    func captureCurrentApplication() {
        targetContext = targetTracker.captureFrontmostApplication()
        if let targetContext { log("Captured target: \(targetContext.name), pid \(targetContext.pid), bundle \(targetContext.bundleIdentifier ?? "unknown")") }
        else { log("Could not capture a target application") }
    }

    func showQuickPanel() {
        if quickPanel.isVisible {
            if isFileDialogActive { quickPanel.focus() }
            else { quickPanel.hide() }
            return
        }
        if !isFileDialogActive {
            captureCurrentApplication()
            panelUseApp = UsageAnalytics.appLabel(bundleIdentifier: targetContext?.bundleIdentifier)
        }
        refreshFinderFolders()
        // A detected file panel owns its target context; otherwise Finder is the destination.
        if !isFileDialogActive { targetContext = nil }
        isShowingAutomatically = false
        quickPanelSessionGeneration &+= 1
        if let activeFilePanelFrame { quickPanel.show(attachedTo: activeFilePanelFrame) }
        else { quickPanel.show() }
    }

    func tryNow() {
        NSApp.hide(nil)
        showQuickPanel()
    }

    func dismissQuickPanel() {
        guard !isFileDialogActive else { return }
        quickPanel.dismiss()
    }

    func finishQuickPanelDrag() { quickPanel.finishDraggingPanel() }

    func setQuickPanelSearchFocus(_ focused: Bool) {
        quickPanelShouldFocusSearch = focused
        quickPanelSearchFocusGeneration += 1
    }

    func openSettings(_ page: SettingsPage) { requestedSettingsPage = page }

    func updateGlobalShortcut(_ shortcut: GlobalShortcut) {
        guard hotkey.update(shortcut: shortcut) else { return }
        globalShortcut = shortcut
        globalShortcut.save()
        globalShortcutStatus = "Shortcut updated to \(shortcut.displayText)"
        log(globalShortcutStatus)
    }

    func navigate(to folder: URL) {
        guard let session = activeFilePanelSession else {
            log("Navigation refused: no verified file-panel session")
            return
        }
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await navigator.navigate(to: folder, session: session, timing: timing)
                guard !Task.isCancelled, self.activeFilePanelSession?.id == session.id else { return }
                recentStore.record(folder)
                log("Navigation completed")
                // Navigation temporarily gives the Save/Open panel keyboard focus.
                // Once the folder change has completed, return it to our search field.
                quickPanel.focus()
            } catch is CancellationError {
                log("Navigation cancelled")
            } catch {
                log("Navigation failed: \(error.localizedDescription)")
            }
            if self.activeFilePanelSession?.id == session.id { self.navigationTask = nil }
        }
    }

    func navigateFromQuickPanel(to folder: URL) {
        capturePanelEvent(.folderSelected)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            log("Navigation refused: folder moved or deleted: \(folder.path)")
            return
        }
        if isFileDialogActive, targetContext != nil {
            // Keep the persistent panel visible, but ensure the synthetic
            // Cmd-Shift-G and path text are delivered to the Save/Open sheet.
            let shieldDuration = max(1.5, Double(timing.activateDelay + timing.goToFolderDelay + timing.inputDelay) / 1_000 + 1.0)
            filePanelDetector.suppressDismissals(for: shieldDuration)
            quickPanel.releaseKeyboardFocus()
            navigate(to: folder)
        } else {
            quickPanel.hide()
            isShowingAutomatically = false
            NSWorkspace.shared.open(folder)
            recentStore.record(folder)
            log("Opened in Finder: \(folder.path)")
        }
    }

    func clearDiagnostics() { diagnostics.removeAll() }

    func recordDiagnostic(_ message: String) { log(message) }

    func refreshFinderFolders() {
        let generation = UUID()
        finderLookupGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let permission = FinderAutomationDiagnostics.permissionStatus(prompt: false)
            guard permission == noErr else {
                DispatchQueue.main.async {
                    guard let self, self.finderLookupGeneration == generation else { return }
                    self.finderFolders = []
                    self.isFinderAccessAvailable = false
                    self.finderLookupStatus = "Finder Automation permission is not enabled."
                }
                return
            }
            let result = Result { try FinderFolderProvider.openWindowFolders() }
            DispatchQueue.main.async {
                guard let self, self.finderLookupGeneration == generation else { return }
                switch result {
                case .success(let query):
                    self.finderFolders = query.folders
                    self.isFinderAccessAvailable = true
                    self.finderLookupStatus = query.folders.isEmpty ? "Finder is available, but has no open folder windows." : "Found \(query.folders.count) Finder folder window(s)."
                    self.log("Finder folders refreshed: \(query.folders.count) readable folder window(s)")
                case .failure(let error):
                    self.finderFolders = []
                    self.isFinderAccessAvailable = false
                    self.finderLookupStatus = "Could not access Finder: \(error.localizedDescription)"
                    self.log("Finder folder lookup unavailable: \(error.localizedDescription)")
                }
            }
        }
    }

    func refreshFinderPermission() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let granted = FinderAutomationDiagnostics.permissionStatus(prompt: false) == noErr
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFinderAccessAvailable = granted
                self.isFinderPermissionChecked = true
                if !granted { self.finderFolders = [] }
            }
        }
    }

    func testFinderAutomationPermission() {
        automationTestStatus = "Requesting Finder Automation permission…"
        finderPermissionMessage = "Waiting for macOS to check Finder access…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FinderAutomationDiagnostics.requestPermissionAndCountWindows()
            DispatchQueue.main.async {
                guard let self else { return }
                var message = "AEDeterminePermissionToAutomateTarget: OSStatus \(result.permissionStatus)"
                if let count = result.windowCount { message += "; Finder windows: \(count)" }
                if let scriptError = result.scriptError { message += "; AppleScript error: \(scriptError)" }
                self.automationTestStatus = message
                self.isFinderAccessAvailable = result.permissionStatus == noErr
                self.isFinderPermissionChecked = true
                self.finderPermissionMessage = result.permissionStatus == noErr
                    ? "Finder access is enabled."
                    : "Finder access is off. Enable FolderBeacon under Automation in System Settings."
                self.log(message)
                if result.permissionStatus == noErr { self.refreshFinderFolders() }
            }
        }
    }

    func chooseProjectFolder(named name: String) {
        let picker = NSOpenPanel()
        picker.title = L10n.format("Choose %@ folder", name)
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = L10n.string("Use Folder")
        if picker.runModal() == .OK, let url = picker.url {
            projectStore.update(name: name, url: url)
            log("Updated \(name) project path: \(url.path)")
        }
    }

    func chooseFavoriteFolder() {
        let picker = NSOpenPanel()
        picker.title = L10n.string("Add Favorite Folder")
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = L10n.string("Add Favorite")
        if picker.runModal() == .OK, let url = picker.url {
            projectStore.add(url: url)
            log("Added favorite: \(url.path)")
        }
    }

    func chooseSearchRoot() {
        let picker = NSOpenPanel()
        picker.title = L10n.string("Add Search Folder")
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = L10n.string("Add Folder")
        guard picker.runModal() == .OK, let url = picker.url else { return }
        Task { [weak self] in
            do { _ = try await self?.folderIndex.addRoot(url) }
            catch { self?.log("Could not add search root: \(error.localizedDescription)") }
        }
    }

    private func log(_ message: String) {
        let line = "[\(Date.now.formatted(date: .omitted, time: .standard))] \(message)"
        diagnostics.append(line)
        if diagnostics.count > 200 { diagnostics.removeFirst(diagnostics.count - 200) }
#if DEBUG
        NSLog("%@", line)
#endif
    }

    private func configureFilePanelDetector() {
        filePanelDetector.onDiagnostic = { [weak self] in self?.log($0) }
        filePanelDetector.onPanelDetected = { [weak self] context in
            guard let self else { return }
            self.navigationTask?.cancel()
            self.activeFilePanelSession = context
            self.targetContext = TargetApplicationContext(
                pid: context.targetApplication.processIdentifier,
                bundleIdentifier: context.targetApplication.bundleIdentifier,
                name: context.targetApplication.localizedName ?? "Unknown App",
                app: context.targetApplication
            )
            self.panelUseApp = UsageAnalytics.appLabel(bundleIdentifier: context.targetApplication.bundleIdentifier)
            self.isFileDialogActive = true
            self.fileDialogTitle = context.title
            self.activeFilePanelFrame = context.frame
            self.quickPanelSessionGeneration &+= 1
            if !self.isShowingAutomatically { self.refreshFinderFolders() }
            self.isShowingAutomatically = true
            if !self.quickPanel.isVisible {
                self.quickPanel.show(attachedTo: context.frame, activating: true)
            }
            self.log("Automatically attached FolderBeacon to \(context.targetApplication.localizedName ?? "Unknown") file panel")
        }
        filePanelDetector.onPanelDismissed = { [weak self] in
            guard let self else { return }
            self.navigationTask?.cancel()
            self.clearFilePanelSession(hideAutomaticPanel: true)
            self.log("Automatically hidden FolderBeacon after file panel closed")
        }
    }

    private func clearFilePanelSession(hideAutomaticPanel: Bool) {
        activeFilePanelSession = nil
        isFileDialogActive = false
        fileDialogTitle = ""
        targetContext = nil
        activeFilePanelFrame = nil
        if hideAutomaticPanel { quickPanel.hide() }
        isShowingAutomatically = false
    }
}
