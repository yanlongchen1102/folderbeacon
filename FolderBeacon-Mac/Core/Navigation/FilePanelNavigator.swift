import AppKit

enum FilePanelNavigationError: LocalizedError {
    case invalidFolder
    case targetCouldNotActivate
    case panelNoLongerAvailable
    case panelDidNotReceiveFocus
    case compactPanelCouldNotExpand
    case pathInputNotFound
    case pathInputRejected
    case submissionCouldNotBeVerified

    var errorDescription: String? {
        switch self {
        case .invalidFolder: "The selected folder no longer exists, is not a directory, or is not readable."
        case .targetCouldNotActivate: "The target application did not become active in time."
        case .panelNoLongerAvailable: "The file dialog is no longer available."
        case .panelDidNotReceiveFocus: "The detected file dialog did not receive keyboard focus."
        case .compactPanelCouldNotExpand: "The compact Save panel could not be expanded safely."
        case .pathInputNotFound: "The Go to Folder field could not be verified, so no path was entered."
        case .pathInputRejected: "The Go to Folder field did not accept the selected path."
        case .submissionCouldNotBeVerified: "The folder change could not be verified."
        }
    }
}

@MainActor
final class FilePanelNavigator {
    private let diagnostics: (String) -> Void
    init(diagnostics: @escaping (String) -> Void) { self.diagnostics = diagnostics }

    func navigate(to folder: URL, session: FilePanelContext, timing: NavigationTiming) async throws {
        try Task.checkCancellation()
        guard isUsableDirectory(folder) else { throw FilePanelNavigationError.invalidFolder }
        guard sessionIsAlive(session) else { throw FilePanelNavigationError.panelNoLongerAvailable }

        let target = session.targetApplication
        diagnostics("Activating \(target.localizedName ?? "target")")
        target.activate(options: [])
        guard await waitForPanelFocus(session, timeoutMilliseconds: max(1_000, timing.activateDelay + 500)) else {
            throw target.isTerminated ? FilePanelNavigationError.targetCouldNotActivate : FilePanelNavigationError.panelDidNotReceiveFocus
        }
        try await wait(milliseconds: timing.activateDelay)
        guard sessionHasFocus(session) else { throw FilePanelNavigationError.panelDidNotReceiveFocus }

        if AXWindowInspector.isCompactSavePanel(session.window) {
            diagnostics("Expanding compact Save panel")
            guard AXWindowInspector.expandCompactSavePanel(session.window),
                  await waitForExpandedFileBrowser(session, timeoutMilliseconds: 1_000) else {
                throw FilePanelNavigationError.compactPanelCouldNotExpand
            }
        }
        guard AXWindowInspector.hasExpandedFileBrowser(session.window) else {
            throw FilePanelNavigationError.compactPanelCouldNotExpand
        }
        let focusedBeforeGoToFolder = AXWindowInspector.focusedElement(for: session.sourcePID)
        guard let focusedBeforeGoToFolder else { throw FilePanelNavigationError.panelDidNotReceiveFocus }

        diagnostics("Sending Cmd-Shift-G")
        KeyboardEventSender.sendShortcut(keyCode: 5, flags: [.maskCommand, .maskShift])
        guard let input = await waitForVerifiedPathInput(session, excluding: focusedBeforeGoToFolder, timeoutMilliseconds: max(800, timing.goToFolderDelay + 500)) else {
            throw FilePanelNavigationError.pathInputNotFound
        }
        diagnostics("Setting verified Go to Folder field")
        guard AXWindowInspector.setValue(folder.path, on: input) else { throw FilePanelNavigationError.pathInputRejected }
        try await wait(milliseconds: timing.inputDelay)
        guard sessionIsAlive(session),
              let focused = AXWindowInspector.focusedElement(for: session.sourcePID),
              AXWindowInspector.isSameElement(focused, input),
              AXWindowInspector.isEditableTextField(focused) else { throw FilePanelNavigationError.panelDidNotReceiveFocus }
        diagnostics("Submitting verified path field")
        KeyboardEventSender.pressReturn()
        guard await waitForPathInputToClose(session, input: input, timeoutMilliseconds: 1_500) else {
            throw FilePanelNavigationError.submissionCouldNotBeVerified
        }
    }

    private func waitForPanelFocus(_ session: FilePanelContext, timeoutMilliseconds: Int) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if sessionHasFocus(session) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return sessionHasFocus(session)
    }

    private func waitForExpandedFileBrowser(_ session: FilePanelContext, timeoutMilliseconds: Int) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            if Task.isCancelled || !sessionIsAlive(session) { return false }
            if AXWindowInspector.hasExpandedFileBrowser(session.window) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return AXWindowInspector.hasExpandedFileBrowser(session.window)
    }

    private func waitForVerifiedPathInput(_ session: FilePanelContext, excluding previousInput: AXUIElement, timeoutMilliseconds: Int) async -> AXUIElement? {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            if Task.isCancelled || !sessionIsAlive(session) { return nil }
            if let focused = AXWindowInspector.focusedElement(for: session.sourcePID),
               AXWindowInspector.isEditableTextField(focused),
               !AXWindowInspector.isSameElement(focused, previousInput),
               AXWindowInspector.isDescendant(focused, of: session.window) {
                return focused
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func waitForPathInputToClose(_ session: FilePanelContext, input: AXUIElement, timeoutMilliseconds: Int) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            guard sessionIsAlive(session) else { return false }
            if !AXWindowInspector.isElementValid(input) { return true }
            if let focused = AXWindowInspector.focusedElement(for: session.sourcePID),
               !AXWindowInspector.isSameElement(focused, input) { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    private func sessionIsAlive(_ session: FilePanelContext) -> Bool {
        !session.targetApplication.isTerminated
            && !session.sourceApplication.isTerminated
            && AXWindowInspector.isWindowValid(session.window, for: session.sourcePID)
    }

    private func sessionHasFocus(_ session: FilePanelContext) -> Bool {
        guard sessionIsAlive(session),
              let focusedPID = AXWindowInspector.focusedApplicationPID(),
              focusedPID == session.targetPID || focusedPID == session.sourcePID else { return false }
        if focusedPID == session.sourcePID {
            guard let focusedWindow = AXWindowInspector.focusedWindow(for: session.sourcePID) else { return false }
            return AXWindowInspector.isSameElement(focusedWindow, session.window)
                || AXWindowInspector.isDescendant(focusedWindow, of: session.window)
        }
        return session.sourcePID == session.targetPID
            && AXWindowInspector.isSameElement(AXWindowInspector.focusedWindow(for: session.targetPID), session.window)
    }

    private func isUsableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private func wait(milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
