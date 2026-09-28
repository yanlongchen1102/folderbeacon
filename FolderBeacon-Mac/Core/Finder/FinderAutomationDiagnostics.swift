import AppKit
import CoreServices

enum FinderAutomationDiagnostics {
    struct Result: Sendable {
        let permissionStatus: OSStatus
        let windowCount: Int?
        let scriptError: String?
    }

    nonisolated static func permissionStatus(prompt: Bool) -> OSStatus {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder").aeDesc else {
            return OSStatus(paramErr)
        }
        return AEDeterminePermissionToAutomateTarget(
            target, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), prompt
        )
    }

    nonisolated static func requestPermissionAndCountWindows() -> Result {
        let status = permissionStatus(prompt: true)
        guard status == noErr else {
            return Result(permissionStatus: status, windowCount: nil, scriptError: nil)
        }

        let script = NSAppleScript(source: "tell application id \"com.apple.finder\" to count Finder windows")
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        return Result(
            permissionStatus: status,
            windowCount: error == nil ? result.map { Int($0.int32Value) } : nil,
            scriptError: error.map { "\($0)" }
        )
    }
}
