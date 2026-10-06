import AppKit

/// Lucide's martini icon, drawn as a resolution-independent macOS template image.
/// https://lucide.dev/icons/martini — ISC license in THIRD_PARTY_NOTICES.txt.
enum MartiniIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scaleX(by: rect.width / 24, yBy: rect.height / 24)
            transform.concat()
            NSColor.black.setStroke()

            let glass = NSBezierPath()
            glass.lineWidth = 2
            glass.lineCapStyle = .round
            glass.lineJoinStyle = .round
            glass.move(to: NSPoint(x: 12, y: 12))
            glass.line(to: NSPoint(x: 4.207, y: 4.207))
            glass.appendArc(withCenter: NSPoint(x: 4.707, y: 3.707), radius: 0.707,
                            startAngle: 135, endAngle: 270, clockwise: false)
            glass.line(to: NSPoint(x: 19.293, y: 3))
            glass.appendArc(withCenter: NSPoint(x: 19.293, y: 3.707), radius: 0.707,
                            startAngle: 270, endAngle: 405, clockwise: false)
            glass.close()
            glass.move(to: NSPoint(x: 12, y: 12))
            glass.line(to: NSPoint(x: 12, y: 22))
            glass.move(to: NSPoint(x: 7, y: 22))
            glass.line(to: NSPoint(x: 17, y: 22))
            glass.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Local Bar"
        return image
    }
}
