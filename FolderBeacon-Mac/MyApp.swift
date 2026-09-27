import SwiftUI

@main
struct FolderBeaconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(state: appDelegate.state)
        }
    }
}
