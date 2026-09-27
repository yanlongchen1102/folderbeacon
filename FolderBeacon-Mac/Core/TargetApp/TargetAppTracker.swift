import AppKit

final class TargetAppTracker {
    func captureFrontmostApplication() -> TargetApplicationContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return TargetApplicationContext(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, name: app.localizedName ?? "Unknown App", app: app)
    }
}
