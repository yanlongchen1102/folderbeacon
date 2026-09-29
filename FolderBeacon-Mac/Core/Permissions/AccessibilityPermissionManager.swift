import ApplicationServices
import AppKit

enum AccessibilityPermissionManager {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func openSettings(pane: String = "Privacy_Accessibility") {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ]
        for address in urls {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }
}
