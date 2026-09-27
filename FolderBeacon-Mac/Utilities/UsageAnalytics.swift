import Foundation
import OSLog

/// Counts only allowlisted actions. Never accepts user content or externally supplied identifiers.
@MainActor
enum UsageAnalytics {
    enum Event: String {
        case panelOpened = "mac_panel_opened"
        case panelClosed = "mac_panel_closed"
        case menuOpened = "mac_menu_opened"
        case menuSearch = "mac_menu_search_clicked"
        case menuSettings = "mac_menu_settings_clicked"
        case menuGettingStarted = "mac_menu_getting_started_clicked"
        case menuUpdates = "mac_menu_updates_clicked"
        case searchUsed = "mac_search_used"
        case folderSelected = "mac_folder_selected"
        case openInFinder = "mac_open_in_finder_clicked"
        case copyPath = "mac_copy_path_clicked"
    }

    // Public project ingestion key, not a personal/admin API key.
    private static let projectKey = "phc_tSzQveQy6AmVWbzopXZ7y6zuttDc5sxxgrnW9M4yNNqW"
    private static let endpoint = URL(string: "https://us.i.posthog.com/i/v0/e/")!
    private static let distinctID = anonymousID(defaults: .standard)

    /// A random installation ID survives app launches and updates without fingerprinting.
    static func anonymousID(defaults: UserDefaults) -> String {
        let key = "FolderBeacon.analytics.anonymousID.v1"
        if let stored = defaults.string(forKey: key), UUID(uuidString: stored) != nil {
            return "mac_" + stored
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        return "mac_" + generated
    }

    private static let logger = Logger(subsystem: "com.yanlongchen.folderbeacon", category: "Analytics")
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    /// Use bundle identifiers rather than user-editable app/window names.
    static func appLabel(bundleIdentifier: String?) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return "unknown" }
        switch bundleIdentifier {
        case "com.google.Chrome": return "chrome"
        case "com.apple.Safari": return "safari"
        case "org.mozilla.firefox": return "firefox"
        case "com.microsoft.edgemac": return "edge"
        case "com.apple.finder": return "finder"
        case "com.apple.dt.Xcode": return "xcode"
        case "com.microsoft.VSCode": return "vscode"
        default: return bundleIdentifier.lowercased()
        }
    }

    static func capture(_ event: Event, useApp: String? = nil) {
        var properties: [String: Any] = [
            "distinct_id": distinctID,
            "$process_person_profile": false,
            "$geoip_disable": true,
            "$ip": "0.0.0.0"
        ]
        if let useApp { properties["use_app"] = useApp }
#if DEBUG
        properties["debug"] = true
#endif
        let payload: [String: Any] = [
            "api_key": projectKey,
            "event": event.rawValue,
            "properties": properties
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Best effort; analytics never blocks UI or writes events to disk.
        let eventName = event.rawValue
        let logger = logger
        logger.info("Sending PostHog event: \(eventName, privacy: .public)")
        session.dataTask(with: request) { _, response, error in
            // Log only fixed event names, HTTP status and numeric transport errors.
            // Never print the payload, key, server body or URL from an error.
            if let error {
                let code = (error as NSError).code
                logger.error("PostHog transport failed: \(eventName, privacy: .public), code=\(code)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                logger.info("PostHog accepted: \(eventName, privacy: .public), HTTP \(status)")
            } else {
                logger.error("PostHog rejected: \(eventName, privacy: .public), HTTP \(status)")
            }
        }.resume()
    }
}
