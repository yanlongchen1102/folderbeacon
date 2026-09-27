import ApplicationServices

final class AXApplicationObserver {
    private let pid: pid_t
    private let onNotification: (AXUIElement, String) -> Void
    private var observer: AXObserver?

    init(pid: pid_t, onNotification: @escaping (AXUIElement, String) -> Void) {
        self.pid = pid
        self.onNotification = onNotification
    }

    @discardableResult
    func start() -> Bool {
        guard observer == nil else { return true }
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            let observer = Unmanaged<AXApplicationObserver>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { observer.onNotification(element, notification as String) }
        }, &created)
        guard status == .success, let created else { return false }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        let app = AXUIElementCreateApplication(pid)
        [kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification].forEach {
            AXObserverAddNotification(created, app, $0 as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        return true
    }

    func observeWindow(_ window: AXUIElement) {
        guard let observer else { return }
        [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification].forEach {
            AXObserverAddNotification(observer, window, $0 as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    deinit { stop() }
}
