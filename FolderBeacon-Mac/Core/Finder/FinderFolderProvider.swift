import AppKit

enum FinderFolderProviderError: LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message): return message
        }
    }
}

struct FinderWindowFolder: Identifiable, Hashable {
    let id: String
    let windowName: String
    let url: URL
}

struct FinderFolderQuery {
    let folders: [FinderWindowFolder]
    let rawResponse: String
}

/// Reads Finder window targets through Apple Events. macOS asks for Automation
/// permission the first time this is used.
enum FinderFolderProvider {
    static func openWindowFolders() throws -> FinderFolderQuery {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
            return FinderFolderQuery(folders: [], rawResponse: "Finder is not running")
        }
        let source = """
        tell application id "com.apple.finder"
            set folderRecords to {}
            set allWindows to every window
            repeat with finderWindow in allWindows
                try
                    set windowTitle to name of finderWindow
                    set folderPath to POSIX path of (target of finderWindow as alias)
                    set end of folderRecords to {windowTitle, folderPath}
                end try
            end repeat
            return folderRecords
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            throw FinderFolderProviderError.executionFailed("Could not create Finder automation script.")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Finder automation was denied."
            throw FinderFolderProviderError.executionFailed(message)
        }

        let folders: [FinderWindowFolder] = (0..<result.numberOfItems).compactMap { offset in
            let index = offset + 1
            guard let record = result.atIndex(index),
                  let windowName = record.atIndex(1)?.stringValue,
                  let path = record.atIndex(2)?.stringValue else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return FinderWindowFolder(id: "\(index)-\(url.path)", windowName: windowName, url: url)
            }
        return FinderFolderQuery(folders: folders, rawResponse: "Structured Finder response with \(folders.count) folder(s)")
    }
}
