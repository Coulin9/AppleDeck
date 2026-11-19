import AppKit

enum VMWindowGeometry {
    static func contentSize(pixels: NSSize, backingScale: CGFloat, available: NSSize) -> NSSize {
        let natural = NSSize(width: pixels.width / backingScale, height: pixels.height / backingScale)
        let scale = min(1, available.width / natural.width, available.height / natural.height)
        return NSSize(width: natural.width * scale, height: natural.height * scale)
    }

    @MainActor
    static func fit(_ window: VMWindow, pixels: NSSize) {
        guard pixels.width > 0, pixels.height > 0, !window.isFullScreen,
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let decoration = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let size = contentSize(pixels: pixels, backingScale: screen.backingScaleFactor,
                               available: NSSize(width: visible.width, height: visible.height - decoration))
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.contentAspectRatio = pixels
        let minimumWidth = min(320, size.width)
        window.contentMinSize = NSSize(width: minimumWidth, height: minimumWidth * pixels.height / pixels.width)
        window.setContentSize(size)
        let x = max(visible.minX, min(center.x - window.frame.width / 2, visible.maxX - window.frame.width))
        let y = max(visible.minY, min(center.y - window.frame.height / 2, visible.maxY - window.frame.height))
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
