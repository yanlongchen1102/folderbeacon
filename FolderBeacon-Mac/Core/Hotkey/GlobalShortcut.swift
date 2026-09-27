import AppKit
import Carbon

struct GlobalShortcut: Codable, Equatable {
    private static let storageKey = "FolderBeacon.globalShortcut.v1"
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let `default` = GlobalShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyLabel: "Space")

    static func load() -> GlobalShortcut {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let shortcut = try? JSONDecoder().decode(GlobalShortcut.self, from: data) else { return .default }
        return shortcut
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    var displayText: String {
        let symbols = [
            (UInt32(cmdKey), "⌘"),
            (UInt32(optionKey), "⌥"),
            (UInt32(controlKey), "⌃"),
            (UInt32(shiftKey), "⇧")
        ].filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        return symbols + keyLabel
    }

    static func from(event: NSEvent) -> GlobalShortcut? {
        guard event.type == .keyDown, event.keyCode != 0 else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonFlags: UInt32 = 0
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        guard carbonFlags != 0 else { return nil }

        let label = keyLabel(for: event)
        return GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: carbonFlags, keyLabel: label)
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case UInt16(kVK_Space): return "Space"
        case UInt16(kVK_Return): return "↩"
        case UInt16(kVK_Tab): return "⇥"
        case UInt16(kVK_Escape): return "⎋"
        case UInt16(kVK_Delete): return "⌫"
        case UInt16(kVK_LeftArrow): return "←"
        case UInt16(kVK_RightArrow): return "→"
        case UInt16(kVK_UpArrow): return "↑"
        case UInt16(kVK_DownArrow): return "↓"
        default:
            let value = event.charactersIgnoringModifiers?.uppercased() ?? ""
            return value.isEmpty ? "Key \(event.keyCode)" : value
        }
    }
}
