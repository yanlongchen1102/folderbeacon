import ApplicationServices
import Foundation

enum AXWindowInspector {
    struct Evidence {
        let role: String
        let labels: [String]
    }

    struct Snapshot {
        let role: String
        let subrole: String
        let title: String
        let isModal: Bool
        let frame: CGRect
        let evidence: [Evidence]
    }

    static func snapshot(of element: AXUIElement) -> Snapshot? {
        guard let frame = frame(of: element), frame.width > 300, frame.height > 180 else { return nil }
        let role = string(kAXRoleAttribute, from: element) ?? ""
        guard role == kAXWindowRole || role == kAXSheetRole else { return nil }
        let subrole = string(kAXSubroleAttribute, from: element) ?? ""
        let title = string(kAXTitleAttribute, from: element) ?? ""
        let isModal = bool(kAXModalAttribute, from: element) ?? false
        let evidence = evidenceInHierarchy(element, depth: 6, limit: 300)
        return Snapshot(role: role, subrole: subrole, title: title, isModal: isModal, frame: frame, evidence: evidence)
    }

    private static let fileViewRoles: Set<String> = [kAXBrowserRole, kAXOutlineRole, kAXTableRole]
    private static let primaryActions: Set<String> = ["open", "save", "choose", "打开", "保存", "选取", "选择"]
    private static let cancelActions: Set<String> = ["cancel", "取消"]

    private static func labels(in snapshot: Snapshot, role: String? = nil) -> [String] {
        snapshot.evidence.filter { role == nil || $0.role == role }.flatMap(\.labels).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func hasActionButtons(_ snapshot: Snapshot) -> Bool {
        let buttons = labels(in: snapshot, role: kAXButtonRole)
        return buttons.contains(where: primaryActions.contains) && buttons.contains(where: cancelActions.contains)
    }

    private static func hasFileView(_ snapshot: Snapshot) -> Bool {
        // A chat history or a web page's scroll area is not a file browser.
        snapshot.evidence.contains { fileViewRoles.contains($0.role) }
    }

    private static func hasCompactSaveControls(_ snapshot: Snapshot) -> Bool {
        let labels = labels(in: snapshot).joined(separator: " ")
        return ["save as", "where", "format", "存储为", "位置", "格式"].contains { labels.contains($0) }
    }

    static func looksLikeFilePanel(_ snapshot: Snapshot) -> String? {
        // Text content and file names must never count as action buttons.
        guard hasActionButtons(snapshot) else { return nil }
        if hasFileView(snapshot) {
            return "role=\(snapshot.role), modal=\(snapshot.isModal), native file view + action buttons"
        }
        if (snapshot.isModal || snapshot.role == kAXSheetRole) && hasCompactSaveControls(snapshot) {
            return "role=\(snapshot.role), modal=\(snapshot.isModal), compact native save controls"
        }
        return nil
    }

    static func windows(for pid: pid_t, diagnostic: ((String) -> Void)? = nil) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement] else {
            diagnostic?("pid=\(pid): AXWindows failed (\(status.rawValue))")
            return []
        }
        // AXWindows can retain a dismissed Open/Save panel with its old controls.
        // Only WindowServer's on-screen windows prove that it is still shown.
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let visibleFrames = windowInfo.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        let visible = windows.filter { window in
            guard bool(kAXMinimizedAttribute, from: window) != true,
                  let frame = frame(of: window) else { return false }
            return hasMatchingVisibleFrame(frame, in: visibleFrames)
        }
        diagnostic?("pid=\(pid): AXWindows=\(windows.count), onScreenFrames=\(visibleFrames), accepted=\(visible.count)")
        return visible
    }

    static func hasMatchingVisibleFrame(_ frame: CGRect, in visibleFrames: [CGRect]) -> Bool {
        visibleFrames.contains {
            abs($0.minX - frame.minX) <= 2 && abs($0.minY - frame.minY) <= 2
                && abs($0.width - frame.width) <= 2 && abs($0.height - frame.height) <= 2
        }
    }

    static func isWindowValid(_ window: AXUIElement, for pid: pid_t) -> Bool {
        windows(for: pid).contains { CFEqual($0, window) }
    }

    static func focusedWindow(for pid: pid_t) -> AXUIElement? {
        element(kAXFocusedWindowAttribute, from: AXUIElementCreateApplication(pid))
    }

    static func focusedElement(for pid: pid_t) -> AXUIElement? {
        element(kAXFocusedUIElementAttribute, from: AXUIElementCreateApplication(pid))
    }

    struct PanelFocusEvidence {
        let windowIsInside: Bool
        let elementIsInside: Bool?

        // A retained panel can still appear in AXWindows and WindowServer.
        // A focused control outside it overrides a stale focused-window value.
        var supportsAttachment: Bool { elementIsInside ?? windowIsInside }
    }

    static func panelFocus(of panel: AXUIElement, for pid: pid_t) -> PanelFocusEvidence {
        let windowMatches = focusedWindow(for: pid).map { isDescendant($0, of: panel) } ?? false
        let elementMatches = focusedElement(for: pid).map { isDescendant($0, of: panel) }
        return PanelFocusEvidence(windowIsInside: windowMatches, elementIsInside: elementMatches)
    }

    static func isSameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    static func isDescendant(_ element: AXUIElement, of ancestor: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<16 {
            guard let candidate = current else { return false }
            if CFEqual(candidate, ancestor) { return true }
            current = self.element(kAXParentAttribute, from: candidate)
        }
        return false
    }

    static func isEditableTextField(_ element: AXUIElement) -> Bool {
        guard string(kAXRoleAttribute, from: element) == kAXTextFieldRole else { return false }
        return bool(kAXEnabledAttribute, from: element) != false
            && bool(kAXFocusedAttribute, from: element) == true
            && isSettable(kAXValueAttribute, on: element)
    }

    static func isElementValid(_ element: AXUIElement) -> Bool {
        string(kAXRoleAttribute, from: element) != nil
    }

    static func isCompactSavePanel(_ window: AXUIElement) -> Bool {
        guard let snapshot = snapshot(of: window) else { return false }
        return !hasFileView(snapshot) && looksLikeFilePanel(snapshot) != nil
    }

    static func hasExpandedFileBrowser(_ window: AXUIElement) -> Bool {
        guard let snapshot = snapshot(of: window) else { return false }
        return hasFileView(snapshot)
    }

    @discardableResult
    static func expandCompactSavePanel(_ window: AXUIElement) -> Bool {
        let disclosureTerms = ["show details", "hide details", "details", "expand", "展开", "显示详细", "隐藏详细", "详细信息"]
        for element in descendants(of: window, depth: 5, limit: 180) {
            guard string(kAXRoleAttribute, from: element) == kAXButtonRole else { continue }
            let labels = [
                string(kAXTitleAttribute, from: element),
                string(kAXDescriptionAttribute, from: element),
                string(kAXHelpAttribute, from: element),
                string(kAXIdentifierAttribute, from: element)
            ].compactMap { $0?.lowercased() }
            guard labels.contains(where: { label in disclosureTerms.contains(where: label.contains) }) else { continue }
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return true }
        }
        return false
    }

    static func setValue(_ value: String, on element: AXUIElement) -> Bool {
        guard isEditableTextField(element),
              AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else { return false }
        return string(kAXValueAttribute, from: element) == value
    }

    static func focusedApplicationPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let app = unsafeBitCast(value, to: AXUIElement.self)
        var pid: pid_t = 0
        return AXUIElementGetPid(app, &pid) == .success ? pid : nil
    }

    private static func evidenceInHierarchy(_ element: AXUIElement, depth: Int, limit: Int) -> [Evidence] {
        guard depth >= 0, limit > 0 else { return [] }
        let role = string(kAXRoleAttribute, from: element) ?? ""
        // Web content can contain arbitrary Open/Save/Cancel controls and tables.
        // Native file panels live outside the application's web area.
        guard role != "AXWebArea" else { return [] }
        let labels = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap {
            string($0, from: element)
        }.filter { !$0.isEmpty }
        var values = [Evidence(role: role, labels: labels)]
        // File entries cannot contribute dialog controls. Avoid scanning large
        // folder lists (and mistaking file names for Save/Cancel labels).
        guard !fileViewRoles.contains(role) else { return values }
        var childValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue) == .success,
           let children = childValue as? [AXUIElement] {
            for child in children.prefix(80) where values.count < limit {
                values += evidenceInHierarchy(child, depth: depth - 1, limit: limit - values.count)
            }
        }
        return values
    }

    private static func descendants(of element: AXUIElement, depth: Int, limit: Int) -> [AXUIElement] {
        guard depth >= 0, limit > 0 else { return [] }
        var result: [AXUIElement] = [element]
        var remaining = limit - 1
        var childValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue) == .success,
              let children = childValue as? [AXUIElement] else { return result }
        for child in children where remaining > 0 {
            let nested = descendants(of: child, depth: depth - 1, limit: remaining)
            result += nested
            remaining -= nested.count
        }
        return result
    }

    private static func string(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ attribute: String, from source: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func bool(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        let position = unsafeBitCast(positionValue, to: AXValue.self)
        let dimensions = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(dimensions, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
