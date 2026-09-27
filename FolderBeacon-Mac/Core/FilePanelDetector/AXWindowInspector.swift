import ApplicationServices
import Foundation

enum AXWindowInspector {
    struct Snapshot {
        let role: String
        let subrole: String
        let title: String
        let isModal: Bool
        let frame: CGRect
        let evidence: [String]
    }

    static func snapshot(of element: AXUIElement) -> Snapshot? {
        guard let frame = frame(of: element), frame.width > 300, frame.height > 180 else { return nil }
        let role = string(kAXRoleAttribute, from: element) ?? ""
        guard role == kAXWindowRole || role == kAXSheetRole else { return nil }
        let subrole = string(kAXSubroleAttribute, from: element) ?? ""
        let title = string(kAXTitleAttribute, from: element) ?? ""
        let isModal = bool(kAXModalAttribute, from: element) ?? false
        let evidence = evidenceInHierarchy(element, depth: 3)
        return Snapshot(role: role, subrole: subrole, title: title, isModal: isModal, frame: frame, evidence: evidence)
    }

    static func looksLikeFilePanel(_ snapshot: Snapshot) -> String? {
        let fileRoles: Set<String> = [kAXBrowserRole, kAXOutlineRole, kAXTableRole, kAXScrollAreaRole]
        let hasFileView = snapshot.evidence.contains { fileRoles.contains($0) }
        let labels = snapshot.evidence.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasPrimaryAction = labels.contains { label in
            ["open", "save", "choose", "打开", "保存", "选取", "选择"].contains(label)
        }
        // A real NSOpenPanel/NSSavePanel always exposes a primary action and
        // Cancel. Requiring both prevents generic lists such as Spotlight from
        // being classified as a file panel merely because they offer "Open".
        let hasCancelAction = labels.contains { ["cancel", "取消"].contains($0) }
        let lower = labels.joined(separator: " ")
        let hasCompactSaveControls = ["save as", "where", "format", "存储为", "位置", "格式"].contains { lower.contains($0) }

        if hasFileView && hasPrimaryAction && hasCancelAction {
            return "role=\(snapshot.role), modal=\(snapshot.isModal), file browser + action controls"
        }
        // Chrome and other apps can present a collapsed NSSavePanel. It has no
        // file browser until expanded, but Cmd-Shift-G still navigates it.
        if (snapshot.isModal || snapshot.role == kAXSheetRole) && hasPrimaryAction && hasCancelAction && hasCompactSaveControls {
            return "role=\(snapshot.role), modal=\(snapshot.isModal), compact native save controls"
        }
        return nil
    }

    static func windows(for pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
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
        let fileRoles: Set<String> = [kAXBrowserRole, kAXOutlineRole, kAXTableRole, kAXScrollAreaRole]
        let hasFileBrowser = snapshot.evidence.contains { fileRoles.contains($0) }
        let labels = snapshot.evidence.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasPrimaryAction = labels.contains { ["open", "save", "choose", "打开", "保存", "选取", "选择"].contains($0) }
        let hasCancelAction = labels.contains { ["cancel", "取消"].contains($0) }
        let lower = labels.joined(separator: " ")
        let hasSaveControls = ["save as", "where", "format", "存储为", "位置", "格式"].contains { lower.contains($0) }
        return !hasFileBrowser && hasPrimaryAction && hasCancelAction && hasSaveControls
    }

    static func hasExpandedFileBrowser(_ window: AXUIElement) -> Bool {
        guard let snapshot = snapshot(of: window) else { return false }
        let fileRoles: Set<String> = [kAXBrowserRole, kAXOutlineRole, kAXTableRole, kAXScrollAreaRole]
        return snapshot.evidence.contains { fileRoles.contains($0) }
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

    private static func evidenceInHierarchy(_ element: AXUIElement, depth: Int) -> [String] {
        guard depth >= 0 else { return [] }
        var values: [String] = []
        if let role = string(kAXRoleAttribute, from: element) { values.append(role) }
        if let title = string(kAXTitleAttribute, from: element), !title.isEmpty { values.append(title) }
        if let value = string(kAXValueAttribute, from: element), !value.isEmpty { values.append(value) }
        if let description = string(kAXDescriptionAttribute, from: element), !description.isEmpty { values.append(description) }
        var childValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue) == .success,
           let children = childValue as? [AXUIElement] {
            for child in children.prefix(80) { values += evidenceInHierarchy(child, depth: depth - 1) }
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
