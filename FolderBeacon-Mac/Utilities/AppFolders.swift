import Foundation

enum AppFolders {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home
    static let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home
}
