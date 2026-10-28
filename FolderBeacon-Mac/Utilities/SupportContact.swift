import Foundation

enum SupportContact {
    static let email = "support@folderbeacon.com"
    static let mailURL = URL(string: "mailto:\(email)?subject=FolderBeacon%20Support")!
}
