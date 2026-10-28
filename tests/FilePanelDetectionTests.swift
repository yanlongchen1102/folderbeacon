import ApplicationServices
import Foundation

// Run with scripts/test-file-panel-detection.sh. These synthetic AX snapshots
// cover the classifier independently of Accessibility permission and running apps.
@main
struct FilePanelDetectionTests {
    @MainActor
    static func main() {
        typealias Evidence = AXWindowInspector.Evidence
        let frame = CGRect(x: 520, y: 181, width: 880, height: 448)
        let open = Evidence(role: kAXButtonRole, labels: ["Open"])
        let save = Evidence(role: kAXButtonRole, labels: ["Save"])
        let cancel = Evidence(role: kAXButtonRole, labels: ["Cancel"])
        let browser = Evidence(role: kAXBrowserRole, labels: [])
        let scroll = Evidence(role: kAXScrollAreaRole, labels: [])
        let filename = Evidence(role: kAXTextFieldRole, labels: ["Save As:"])
        var count = 0

        func check(_ name: String, _ condition: Bool) {
            guard condition else { fatalError("FAIL: \(name)") }
            count += 1
            print("PASS: \(name)")
        }
        func snapshot(_ evidence: [Evidence], modal: Bool = false, role: String = kAXWindowRole) -> AXWindowInspector.Snapshot {
            .init(role: role, subrole: "AXStandardWindow", title: "Select files", isModal: modal, frame: frame, evidence: evidence)
        }
        func detected(_ evidence: [Evidence], modal: Bool = false, role: String = kAXWindowRole) -> Bool {
            AXWindowInspector.looksLikeFilePanel(snapshot(evidence, modal: modal, role: role)) != nil
        }

        check("nonmodal native Open panel remains supported", detected([browser, open, cancel]))
        check("expanded Save panel remains supported", detected([browser, filename, save, cancel]))
        check("native list view remains supported", detected([.init(role: kAXTableRole, labels: []), open, cancel]))
        check("native outline view remains supported", detected([.init(role: kAXOutlineRole, labels: []), open, cancel]))
        check("Chinese button descriptions remain supported", detected([browser, .init(role: kAXButtonRole, labels: ["  选择\n"]), .init(role: kAXButtonRole, labels: ["取消"])]))
        check("collapsed modal Save panel remains supported", detected([filename, save, cancel], modal: true))
        check("collapsed Save sheet remains supported", detected([filename, save, cancel], role: kAXSheetRole))
        check("scrolling chat with Open and Cancel text is rejected", !detected([scroll, .init(role: kAXStaticTextRole, labels: ["Open", "Cancel"])]))
        check("scrolling page with real Open and Cancel buttons is rejected", !detected([scroll, open, cancel]))
        check("sidebar plus text labels is rejected", !detected([.init(role: kAXOutlineRole, labels: []), .init(role: kAXStaticTextRole, labels: ["Open", "Cancel"])]))
        check("text fields cannot impersonate action buttons", !detected([browser, .init(role: kAXTextFieldRole, labels: ["Open"]), cancel]))
        check("Open alone is insufficient", !detected([browser, open]))
        check("ordinary settings form is not a collapsed Save panel", !detected([filename, save, cancel]))
        check("generic confirmation modal is rejected", !detected([save, cancel], modal: true))

        let mainWindow = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        check("visible native panel matches WindowServer", AXWindowInspector.hasMatchingVisibleFrame(frame, in: [mainWindow, frame]))
        check("stale hidden Select files panel is rejected despite live host", !AXWindowInspector.hasMatchingVisibleFrame(frame, in: [mainWindow]))
        check("off-space or closed window is rejected", !AXWindowInspector.hasMatchingVisibleFrame(frame, in: []))
        check("minor accessibility frame rounding is tolerated", AXWindowInspector.hasMatchingVisibleFrame(frame, in: [frame.offsetBy(dx: 1, dy: -1)]))
        check("another window at the same origin is insufficient", !AXWindowInspector.hasMatchingVisibleFrame(frame, in: [CGRect(x: 520, y: 181, width: 1200, height: 800)]))
        typealias Focus = AXWindowInspector.PanelFocusEvidence
        check("retained panel with focus in chat is rejected", !Focus(windowIsInside: false, elementIsInside: false).supportsAttachment)
        check("chat focus overrides stale focused-window metadata", !Focus(windowIsInside: true, elementIsInside: false).supportsAttachment)
        check("focused native panel remains supported", Focus(windowIsInside: true, elementIsInside: true).supportsAttachment)
        check("focused control in sheet works when focused window is its parent", Focus(windowIsInside: false, elementIsInside: true).supportsAttachment)
        check("missing AX focus fails closed without a focused panel window", !Focus(windowIsInside: false, elementIsInside: nil).supportsAttachment)
        check("focused panel window supports hosts without focused-control attribute", Focus(windowIsInside: true, elementIsInside: nil).supportsAttachment)
        print("All \(count) file-panel detection checks passed.")
    }
}
