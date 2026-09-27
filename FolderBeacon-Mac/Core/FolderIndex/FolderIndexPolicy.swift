import Foundation

struct FolderIndexPolicy: Sendable {
    func shouldIndex(_ url: URL, values: URLResourceValues, root: SearchRoot) -> Bool {
        guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
        let name = url.lastPathComponent
        // These directory trees are generated metadata or dependency caches. They
        // add a disproportionate number of folders but are poor navigation targets.
        let noisyNames: Set<String> = [".git", "node_modules", "DerivedData", "Pods", ".swiftpm", "Caches"]
        if noisyNames.contains(name) { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if root.url.standardizedFileURL == home, url.deletingLastPathComponent().standardizedFileURL == home,
           name == "Library" || name == ".Trash" { return false }
        if values.isPackage == true { return true } // Index the package itself, never its contents.
        if !root.includeHiddenFolders && (values.isHidden == true || name.hasPrefix(".")) { return false }
        return true
    }

    func shouldDescend(into values: URLResourceValues) -> Bool {
        values.isDirectory == true && values.isPackage != true && values.isSymbolicLink != true
    }
}
