import AppKit
import SwiftUI

private final class FocusablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    private weak var state: AppState?
    private let panel: NSPanel
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var dragOrigin: NSPoint?
    private(set) var isVisible = false

    init(state: AppState) {
        self.state = state
        panel = FocusablePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 270), styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        // Standard file panels use a modal level, which is above .floating.
        // popUpMenu keeps our non-activating picker visible above that panel.
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickPanelView(state: state, projects: state.projectStore, movePanel: { [weak self] translation in
            self?.move(by: translation)
        }))
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 18
        panel.contentView?.layer?.masksToBounds = true
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 70))
        }
        present()
    }

    func show(attachedTo accessibilityFrame: CGRect, activating: Bool = true) {
        let cocoaFrame = cocoaFrame(fromAccessibilityFrame: accessibilityFrame)
        let screen = screen(containing: cocoaFrame)
        if let screen {
            let visible = screen.visibleFrame
            let x = min(max(cocoaFrame.midX - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width)
            let dialogBottom = cocoaFrame.minY
            let preferredY = dialogBottom - 12 - panel.frame.height
            let y = min(max(visible.minY, preferredY), visible.maxY - panel.frame.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        present(activating: activating)
    }

    private func present(activating: Bool = true) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if activating { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
        state?.setQuickPanelSearchFocus(activating)
        if !isVisible { state?.capturePanelEvent(.panelOpened) }
        isVisible = true
        // A panel attached to an Open/Save sheet is persistent for the sheet's
        // lifetime. In Finder mode it keeps the usual transient behaviour.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Global-monitor events retain the source app's window coordinates.
            // Compare in screen coordinates so clicks in our panel are not
            // mistaken for outside clicks.
            guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            if self.state?.isFileDialogActive == true { self.releaseKeyboardFocus() }
            else { self.hide() }
        }
        guard state?.isFileDialogActive != true else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.hide() }
        }
    }

    func hide() {
        if isVisible { state?.capturePanelEvent(.panelClosed) }
        state?.resetSearchUsage()
        panel.orderOut(nil)
        state?.setQuickPanelSearchFocus(false)
        isVisible = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideClickMonitor = nil
        escapeMonitor = nil
    }

    func dismiss() { hide() }

    func releaseKeyboardFocus() {
        let wasKey = panel.isKeyWindow
        state?.setQuickPanelSearchFocus(false)
        panel.makeFirstResponder(nil)
        guard wasKey, isVisible else { return }
        // Release the nonactivating panel's key focus while keeping the visible
        // result atomic. Never leave it ordered out across a run-loop turn.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func focus() {
        panel.makeKeyAndOrderFront(nil)
        state?.setQuickPanelSearchFocus(true)
    }

    private func cocoaFrame(fromAccessibilityFrame frame: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return frame }
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).width * lhs.frame.intersection(frame).height
                < rhs.frame.intersection(frame).width * rhs.frame.intersection(frame).height
        } ?? NSScreen.main
    }

    private func move(by translation: CGSize) {
        if dragOrigin == nil { dragOrigin = panel.frame.origin }
        guard let dragOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: dragOrigin.x + translation.width, y: dragOrigin.y - translation.height))
    }

    func finishDraggingPanel() { dragOrigin = nil }

    func windowWillClose(_ notification: Notification) { hide() }
}
