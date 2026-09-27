import CoreServices
import Foundation

/// FSEvents is deliberately only a change hint. The coordinator subsequently
/// reads the directory and reconciles SQLite from the filesystem's current state.
final class FolderIndexEventWatcher: @unchecked Sendable {
    struct Event: Sendable {
        let rootID: UUID
        let path: String
        let mustScanSubdirectories: Bool
        let eventID: UInt64
    }

    var onEvents: (@Sendable ([Event]) -> Void)?
    private let queue = DispatchQueue(label: "com.folderbeacon.fsevents")
    private var streams: [UUID: FSEventStreamRef] = [:]
    private var roots: [UUID: URL] = [:]

    func start(root: SearchRoot) {
        stop(rootID: root.id)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var streamContext = FSEventStreamContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &streamContext, [root.url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else { return }
        roots[root.id] = root.url.standardizedFileURL
        streams[root.id] = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop(rootID: UUID) {
        roots.removeValue(forKey: rootID)
        guard let stream = streams.removeValue(forKey: rootID) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func stopAll() { Array(streams.keys).forEach(stop(rootID:)) }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let watcher = Unmanaged<FolderIndexEventWatcher>.fromOpaque(info).takeUnretainedValue()
        let receivedPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        var events: [Event] = []
        for index in 0..<Int(count) {
            let path = URL(fileURLWithPath: receivedPaths[index]).standardizedFileURL.path
            guard let (id, root) = watcher.roots.first(where: { FolderIndexEventWatcher.contains($0.value.path, path) }) else { continue }
            let flag = flags[index]
            let needsRecursiveScan = (flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs)) != 0 ||
                (flag & UInt32(kFSEventStreamEventFlagUserDropped)) != 0 ||
                (flag & UInt32(kFSEventStreamEventFlagKernelDropped)) != 0 ||
                (flag & UInt32(kFSEventStreamEventFlagRootChanged)) != 0
            events.append(Event(rootID: id, path: needsRecursiveScan ? root.path : path, mustScanSubdirectories: needsRecursiveScan, eventID: ids[index]))
        }
        if !events.isEmpty { watcher.onEvents?(events) }
    }

    private static func contains(_ root: String, _ path: String) -> Bool {
        let rootParts = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let pathParts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return rootParts.count <= pathParts.count && zip(rootParts, pathParts).allSatisfy(==)
    }
}
