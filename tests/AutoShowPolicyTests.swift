import Foundation

@main
struct AutoShowPolicyTests {
    @MainActor static func main() throws {
        let suite = "FolderBeacon.AutoShowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appURL = root.appendingPathComponent("Example.app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = ["CFBundleIdentifier": "test.example.host", "CFBundleName": "Example", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        guard let app = AppException(url: appURL) else { fatalError("Could not read app fixture") }
        let policy = AutoShowPolicy(defaults: defaults)
        precondition(policy.enabled && policy.exceptions.isEmpty && policy.allows(app.id))
        policy.add(app)
        policy.add(app)
        precondition(policy.exceptions.count == 1 && !policy.allows(app.id) && policy.allows("other.host"))
        policy.enabled = false
        precondition(!policy.allows("other.host") && policy.exceptions.count == 1)
        let reloaded = AutoShowPolicy(defaults: defaults)
        precondition(!reloaded.enabled && reloaded.exceptions == [app])
        reloaded.enabled = true
        precondition(!reloaded.allows(app.id) && reloaded.allows("other.host"))
        reloaded.remove(app.id)
        precondition(reloaded.allows(app.id) && AutoShowPolicy(defaults: defaults).exceptions.isEmpty)
        print("PASS: defaults, identity, deduplication, switch, persistence, and removal")
    }
}
