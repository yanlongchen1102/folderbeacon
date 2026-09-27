import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let onCapture: (GlobalShortcut) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onCapture = onCapture
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    final class CaptureView: NSView {
        var onCapture: ((GlobalShortcut) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard let shortcut = GlobalShortcut.from(event: event) else {
                NSSound.beep()
                return
            }
            onCapture?(shortcut)
        }

        override func cancelOperation(_ sender: Any?) {
            window?.makeFirstResponder(nil)
        }
    }
}
