import AppKit
import ApplicationServices

struct FilePanelContext {
    let id: UUID
    let targetApplication: NSRunningApplication
    let sourceApplication: NSRunningApplication
    let window: AXUIElement
    let frame: CGRect
    let title: String
    let reason: String
    let detectedAt: Date

    var targetPID: pid_t { targetApplication.processIdentifier }
    var sourcePID: pid_t { sourceApplication.processIdentifier }
}
