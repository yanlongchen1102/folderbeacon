import CoreGraphics

enum KeyboardEventSender {
    static func sendShortcut(keyCode: CGKeyCode, flags: CGEventFlags) { sendKey(keyCode, flags: flags) }
    static func pressReturn() { sendKey(36) }

    static func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let units = Array(text.utf16)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
        }
    }
}
