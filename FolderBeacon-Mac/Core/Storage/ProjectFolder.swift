import Foundation

struct ProjectFolder: Codable, Identifiable {
    let id: UUID
    var name: String
    var path: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}
