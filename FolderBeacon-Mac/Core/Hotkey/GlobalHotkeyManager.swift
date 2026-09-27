import Carbon

final class GlobalHotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private let handler: () -> Void
    private let registrationResult: (String) -> Void
    private var eventHandler: EventHandlerRef?
    private var registeredShortcut: GlobalShortcut?

    init(handler: @escaping () -> Void, registrationResult: @escaping (String) -> Void) {
        self.handler = handler
        self.registrationResult = registrationResult
    }

    @discardableResult
    func start(shortcut: GlobalShortcut) -> Bool {
        installEventHandlerIfNeeded()
        guard hotKeyRef == nil else { return true }
        return register(shortcut)
    }

    @discardableResult
    func update(shortcut: GlobalShortcut) -> Bool {
        guard shortcut != registeredShortcut else { return true }
        let previous = registeredShortcut
        unregisterHotKey()
        guard register(shortcut) else {
            if let previous { _ = register(previous) }
            return false
        }
        return true
    }

    private func register(_ shortcut: GlobalShortcut) -> Bool {
        let identifier = EventHotKeyID(signature: OSType(0x5050_4C54), id: 1) // PPLT
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            registrationResult("\(shortcut.displayText) registration failed (OSStatus \(status)). Another app or macOS owns this shortcut.")
            return false
        }
        registeredShortcut = shortcut
        registrationResult("\(shortcut.displayText) global shortcut registered")
        return true
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.handler() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    func stop() {
        unregisterHotKey()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registeredShortcut = nil
    }

    deinit { stop() }
}
