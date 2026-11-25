import CoreGraphics

/// How far a window edge may be from the screen edge and still count as flush with it.
public let flushTolerance: CGFloat = 2

/// The frame a window should get to stay out of a Dock, or `nil` when it is left as it is.
///
/// Only a window whose edge is flush with the Dock's screen edge is corrected: that edge moves to the Dock's
/// inner edge and the opposite edge stays, so the window gets smaller. A window that merely overlaps the Dock
/// is left alone, as is a window whose centre is not on `screen` (it is on another monitor).
/// All rectangles are in AppKit screen coordinates (bottom-left origin).
public func frameClearOfDock(window: CGRect, screen: CGRect, edge: DockPosition, dockThickness: CGFloat) -> CGRect? {
    guard screen.contains(CGPoint(x: window.midX, y: window.midY)) else { return nil }
    var frame = window
    switch edge {
    case .left:
        guard abs(window.minX - screen.minX) <= flushTolerance else { return nil }
        frame.origin.x = screen.minX + dockThickness
        frame.size.width = window.maxX - frame.minX
    case .right:
        guard abs(window.maxX - screen.maxX) <= flushTolerance else { return nil }
        frame.size.width = screen.maxX - dockThickness - window.minX
    case .bottom:
        guard abs(window.minY - screen.minY) <= flushTolerance else { return nil }
        frame.origin.y = screen.minY + dockThickness
        frame.size.height = window.maxY - frame.minY
    }
    return frame.width > 0 && frame.height > 0 ? frame : nil
}

/// Converts between AppKit screen coordinates (bottom-left origin) and Accessibility coordinates
/// (top-left origin of the primary screen). The conversion is the same in both directions.
public func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}
