import AppKit
import Combine

struct AppException: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    let path: String?

    init?(application: NSRunningApplication) {
        guard let id = application.bundleIdentifier, !id.isEmpty,
              id != Bundle.main.bundleIdentifier,
              id != "com.apple.appkit.xpc.openAndSavePanelService" else { return nil }
        bundleIdentifier = id
        name = application.localizedName ?? id
        path = application.bundleURL?.path
    }

    init?(url: URL) {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, !id.isEmpty,
              id != Bundle.main.bundleIdentifier,
              id != "com.apple.appkit.xpc.openAndSavePanelService" else { return nil }
        bundleIdentifier = id
        name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        path = url.path
    }
}

@MainActor
final class AutoShowPolicy: ObservableObject {
    private let defaults: UserDefaults
    private let enabledKey = "FolderBeacon.autoShow.enabled"
    private let exceptionsKey = "FolderBeacon.autoShow.exceptions"
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: enabledKey) } }
    @Published private(set) var exceptions: [AppException] { didSet { defaults.set(try? JSONEncoder().encode(exceptions), forKey: exceptionsKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        exceptions = defaults.data(forKey: exceptionsKey).flatMap { try? JSONDecoder().decode([AppException].self, from: $0) } ?? []
    }
    func allows(_ bundleIdentifier: String?) -> Bool {
        enabled && !exceptions.contains { $0.bundleIdentifier == bundleIdentifier }
    }
    func add(_ app: AppException) {
        guard !exceptions.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        exceptions.append(app)
    }
    func remove(_ id: String) { exceptions.removeAll { $0.bundleIdentifier == id } }
}
