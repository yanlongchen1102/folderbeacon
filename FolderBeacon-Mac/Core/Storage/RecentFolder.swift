import Foundation

struct RecentFolder: Codable, Identifiable {
    var id: String { path }
    var path: String
    var displayName: String
    var lastUsedAt: Date
    var useCount: Int
}
