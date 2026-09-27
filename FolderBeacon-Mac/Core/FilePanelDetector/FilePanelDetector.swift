import AppKit
import ApplicationServices

@MainActor
final class FilePanelDetector {
    var onPanelDetected: ((FilePanelContext) -> Void)?
    var onPanelDismissed: (() -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private let panelServiceBundleID = "com.apple.appkit.xpc.openAndSavePanelService"
    private let excludedSystemUIBundleIDs: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.AppStore",
        "com.apple.storeagent"
    ]
    private var appObservers: [pid_t: AXApplicationObserver] = [:]
    private var workspaceObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var currentApplication: NSRunningApplication?
    private var activeContext: FilePanelContext?
    private var burstTasks: [Task<Void, Never>] = []
    private var dismissalWatchdog: Task<Void, Never>?
    private var activePanelWatchdog: Task<Void, Never>?
    private var consecutiveMissingScans = 0
    private var dismissalsSuppressedUntil = Date.distantPast
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        guard AccessibilityPermissionManager.isTrusted else {
            onDiagnostic?("Automatic detection unavailable: Accessibility permission is not granted")
            return
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.async { self?.handleApplicationActivation(app) }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appObservers.removeValue(forKey: app.processIdentifier)?.stop()
                if self.activeContext?.sourcePID == app.processIdentifier || self.activeContext?.targetPID == app.processIdentifier {
                    self.dismissActiveContext(reason: "The file-panel process terminated")
                }
            }
        }
        isRunning = true
        if let app = NSWorkspace.shared.frontmostApplication { observe(application: app) }
        onDiagnostic?("Automatic file-panel detection started")
    }

    func stop() {
        burstTasks.forEach { $0.cancel() }
        burstTasks.removeAll()
        dismissalWatchdog?.cancel()
        dismissalWatchdog = nil
        activePanelWatchdog?.cancel()
        activePanelWatchdog = nil
        appObservers.values.forEach { $0.stop() }
        appObservers.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        workspaceObserver = nil
        terminationObserver = nil
        activeContext = nil
        consecutiveMissingScans = 0
        isRunning = false
    }

    private func observe(application: NSRunningApplication) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard !excludedSystemUIBundleIDs.contains(application.bundleIdentifier ?? "") else {
            onDiagnostic?("Ignoring system UI: \(application.localizedName ?? "Unknown")")
            return
        }
        if application.bundleIdentifier != panelServiceBundleID { currentApplication = application }
        installObserver(for: application)
        onDiagnostic?("Observing \(application.localizedName ?? "Unknown") (pid \(application.processIdentifier)) for file panels")
        scheduleDetectionBurst()
    }

    private func handleApplicationActivation(_ application: NSRunningApplication) {
        if let activeContext,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           application.processIdentifier != activeContext.targetPID,
           application.processIdentifier != activeContext.sourcePID {
            dismissActiveContext(reason: "File-panel session invalidated after the user switched applications")
        }
        observe(application: application)
    }

    private func installObserver(for application: NSRunningApplication) {
        guard appObservers[application.processIdentifier] == nil else { return }
        let observer = AXApplicationObserver(pid: application.processIdentifier) { [weak self] _, notification in
            self?.handleAccessibilityEvent(notification)
        }
        if observer.start() {
            appObservers[application.processIdentifier] = observer
        } else {
            onDiagnostic?("Could not install Accessibility observer for pid \(application.processIdentifier); will retry")
        }
    }

    private func handleAccessibilityEvent(_ notification: String) {
        onDiagnostic?("AX event: \(notification)")
        scheduleDetectionBurst()
    }

    func suppressDismissals(for seconds: TimeInterval) {
        dismissalsSuppressedUntil = max(dismissalsSuppressedUntil, Date.now.addingTimeInterval(seconds))
        dismissalWatchdog?.cancel()
        dismissalWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, Date.now >= self.dismissalsSuppressedUntil else { return }
            for delay in [0, 100, 250, 500] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled else { return }
                self.scan()
            }
        }
    }

    private func scheduleDetectionBurst() {
        burstTasks.forEach { $0.cancel() }
        burstTasks = [0, 100, 250, 500].map { delay in
            Task { [weak self] in
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled else { return }
                self?.scan()
            }
        }
    }

    private func scan() {
        guard let targetApplication = currentApplication else { return }
        if let activeContext,
           AXWindowInspector.isWindowValid(activeContext.window, for: activeContext.sourcePID),
           let snapshot = AXWindowInspector.snapshot(of: activeContext.window),
           AXWindowInspector.looksLikeFilePanel(snapshot) != nil {
            consecutiveMissingScans = 0
            return
        }

        let panelServices = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == panelServiceBundleID }
        if let focusedPID = AXWindowInspector.focusedApplicationPID(),
           let focused = NSRunningApplication(processIdentifier: focusedPID),
           focused.processIdentifier != targetApplication.processIdentifier,
           focused.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           focused.bundleIdentifier != panelServiceBundleID {
            installObserver(for: focused)
        }

        let directCandidates = candidates(in: targetApplication)
        if directCandidates.count == 1, let candidate = directCandidates.first {
            accept(candidate, target: targetApplication)
            return
        }
        if directCandidates.count > 1 {
            onDiagnostic?("Automatic attachment refused: multiple file panels belong to \(targetApplication.localizedName ?? "the target app")")
            recordMissingCandidate()
            return
        }

        let focusedPID = AXWindowInspector.focusedApplicationPID()
        let serviceCandidates = panelServices.flatMap { candidates(in: $0) }
        if serviceCandidates.count == 1,
           let candidate = serviceCandidates.first,
           focusedPID == candidate.application.processIdentifier,
           targetApplication.isActive {
            accept(candidate, target: targetApplication)
            return
        }
        if serviceCandidates.count > 1 {
            onDiagnostic?("Automatic attachment refused: multiple unowned file-panel services are visible")
        }
        recordMissingCandidate()
    }

    private typealias Candidate = (application: NSRunningApplication, window: AXUIElement, snapshot: AXWindowInspector.Snapshot, reason: String)

    private func candidates(in application: NSRunningApplication) -> [Candidate] {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !excludedSystemUIBundleIDs.contains(application.bundleIdentifier ?? "") else { return [] }
        installObserver(for: application)
        return AXWindowInspector.windows(for: application.processIdentifier).compactMap { window in
            guard let snapshot = AXWindowInspector.snapshot(of: window),
                  let reason = AXWindowInspector.looksLikeFilePanel(snapshot) else { return nil }
            return (application, window, snapshot, reason)
        }
    }

    private func accept(_ candidate: Candidate, target: NSRunningApplication) {
        let context = FilePanelContext(
            id: UUID(),
            targetApplication: target,
            sourceApplication: candidate.application,
            window: candidate.window,
            frame: candidate.snapshot.frame,
            title: candidate.snapshot.title,
            reason: "source=\(candidate.application.bundleIdentifier ?? "unknown"); \(candidate.reason)",
            detectedAt: .now
        )
        activeContext = context
        consecutiveMissingScans = 0
        activePanelWatchdog?.cancel()
        activePanelWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.activeContext?.id == context.id else { return }
                self.scan()
            }
        }
        appObservers[candidate.application.processIdentifier]?.observeWindow(candidate.window)
        onDiagnostic?("Open/Save candidate: source=\(candidate.application.localizedName ?? "Unknown"), target=\(target.localizedName ?? "Unknown"), title=\(candidate.snapshot.title), role=\(candidate.snapshot.role), subrole=\(candidate.snapshot.subrole), modal=\(candidate.snapshot.isModal), frame=\(candidate.snapshot.frame), reason=\(context.reason)")
        onPanelDetected?(context)
    }

    private func recordMissingCandidate() {
        guard activeContext != nil, Date.now >= dismissalsSuppressedUntil else { return }
        consecutiveMissingScans += 1
        guard consecutiveMissingScans >= 4 else { return }
        dismissActiveContext(reason: "Open/Save panel no longer detected")
    }

    private func dismissActiveContext(reason: String) {
        guard activeContext != nil else { return }
        activePanelWatchdog?.cancel()
        activePanelWatchdog = nil
        activeContext = nil
        consecutiveMissingScans = 0
        onDiagnostic?(reason)
        onPanelDismissed?()
    }
}
