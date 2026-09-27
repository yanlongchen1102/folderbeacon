import AppKit

struct TargetApplicationContext {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
    let app: NSRunningApplication
}
