import AppKit

enum BrandIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let mark = NSBezierPath()
            mark.windingRule = .evenOdd

            // Keep the visible folder nearly square at menu bar size.
            mark.move(to: NSPoint(x: 2.9, y: 1.4))
            mark.curve(to: NSPoint(x: 1.4, y: 2.9), controlPoint1: NSPoint(x: 2.1, y: 1.4), controlPoint2: NSPoint(x: 1.4, y: 2.1))
            mark.line(to: NSPoint(x: 1.4, y: 14.7))
            mark.curve(to: NSPoint(x: 2.9, y: 16.2), controlPoint1: NSPoint(x: 1.4, y: 15.5), controlPoint2: NSPoint(x: 2.1, y: 16.2))
            mark.line(to: NSPoint(x: 6.8, y: 16.2))
            mark.curve(to: NSPoint(x: 7.9, y: 15.7), controlPoint1: NSPoint(x: 7.3, y: 16.2), controlPoint2: NSPoint(x: 7.6, y: 16.0))
            mark.line(to: NSPoint(x: 9.0, y: 14.5))
            mark.curve(to: NSPoint(x: 10.0, y: 14.0), controlPoint1: NSPoint(x: 9.3, y: 14.1), controlPoint2: NSPoint(x: 9.6, y: 14.0))
            mark.line(to: NSPoint(x: 15.1, y: 14.0))
            mark.curve(to: NSPoint(x: 16.6, y: 12.5), controlPoint1: NSPoint(x: 15.9, y: 14.0), controlPoint2: NSPoint(x: 16.6, y: 13.3))
            mark.line(to: NSPoint(x: 16.6, y: 2.9))
            mark.curve(to: NSPoint(x: 15.1, y: 1.4), controlPoint1: NSPoint(x: 16.6, y: 2.1), controlPoint2: NSPoint(x: 15.9, y: 1.4))
            mark.close()

            // Transparent swoosh and beacon retain the original logo's detail.
            mark.move(to: NSPoint(x: 2.0, y: 2.7))
            mark.curve(to: NSPoint(x: 13.0, y: 10.4), controlPoint1: NSPoint(x: 4.2, y: 7.0), controlPoint2: NSPoint(x: 9.4, y: 10.0))
            mark.curve(to: NSPoint(x: 6.3, y: 1.8), controlPoint1: NSPoint(x: 7.8, y: 8.7), controlPoint2: NSPoint(x: 4.6, y: 4.0))
            mark.close()
            mark.appendOval(in: NSRect(x: 12.6, y: 9.9, width: 2.6, height: 2.6))

            NSColor.black.setFill()
            mark.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "FolderBeacon"
        return image
    }
}
