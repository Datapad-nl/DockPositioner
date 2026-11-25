import CoreGraphics
import Foundation

/// Geometry of the Dock panel on one monitor.
///
/// Screen coordinates (`screen`, `frame`, `dockRect`, pointer) have a bottom-left origin, like AppKit.
/// View coordinates (`point(along:across:)`) have a top-left origin, like SwiftUI, inside the panel.
/// "Along" runs along the edge (left to right, or top to bottom); "across" runs away from the edge.
public struct DockLayout: Equatable, Sendable {
    public static let maxMagnification: CGFloat = 1.6
    /// How close the pointer must come to the edge to bring back an auto-hidden Dock.
    public static let revealDistance: CGFloat = 3

    public let edge: DockPosition
    public let magnification: Bool
    public let itemCount: Int
    public let screen: CGRect
    /// Height of the menu bar at the top of the monitor; side Docks are centred below it.
    public let topInset: CGFloat
    /// Icon size in points, shrunk when needed so the Dock fits on the monitor.
    public private(set) var iconSize: CGFloat

    /// Icon size for a profile size of 0...1, roughly the range of the system Dock.
    public static func iconSize(forSize size: Double) -> CGFloat {
        16 + 112 * CGFloat(min(max(size, 0), 1))
    }

    public init(settings: DockSettings, itemCount: Int, screen: CGRect, topInset: CGFloat = 0) {
        edge = settings.position
        magnification = settings.magnification
        self.itemCount = itemCount
        self.screen = screen
        self.topInset = topInset
        iconSize = Self.iconSize(forSize: settings.size)
        let available = edge == .bottom ? screen.width : screen.height - topInset
        while iconSize > 16, length > available {
            iconSize -= 1
        }
    }

    public var pad: CGFloat { max(5, (iconSize * 0.12).rounded()) }
    public var slot: CGFloat { iconSize + pad }
    /// Size of the rounded background along the edge.
    public var dockLength: CGFloat { CGFloat(itemCount) * slot + pad }
    /// Size of the rounded background across the edge.
    public var dockThickness: CGFloat { iconSize + 2 * pad }
    /// Room for a name label beyond the icons: its height under a bottom Dock, its width beside a side Dock.
    public var labelSpace: CGFloat { edge == .bottom ? 28 : 200 }

    private var growth: CGFloat { magnification ? iconSize * (Self.maxMagnification - 1) : 0 }
    /// How far an icon hops away from the edge when its app asks for attention: half an icon, but never beyond
    /// the panel, also when the icon is fully magnified.
    public var bounceHeight: CGFloat {
        let largest = magnification ? iconSize * Self.maxMagnification : iconSize
        return min(iconSize / 2, thickness - pad - largest)
    }

    /// Room at both ends along the edge for magnified end icons and labels.
    private var margin: CGFloat { edge == .bottom ? max(90, growth / 2) : growth / 2 }
    private var length: CGFloat { dockLength + 2 * margin }
    private var thickness: CGFloat { dockThickness + growth + 6 + labelSpace }

    /// The panel's frame: centred along the edge of the monitor.
    public var frame: CGRect {
        let sideY = ((screen.minY + screen.maxY - topInset - length) / 2).rounded()
        switch edge {
        case .bottom: return CGRect(x: (screen.midX - length / 2).rounded(), y: screen.minY, width: length, height: thickness)
        case .left: return CGRect(x: screen.minX, y: sideY, width: thickness, height: length)
        case .right: return CGRect(x: screen.maxX - thickness, y: sideY, width: thickness, height: length)
        }
    }

    /// The frame slid off the edge, for an auto-hidden Dock.
    public var hiddenFrame: CGRect {
        switch edge {
        case .bottom: return frame.offsetBy(dx: 0, dy: -dockThickness)
        case .left: return frame.offsetBy(dx: -dockThickness, dy: 0)
        case .right: return frame.offsetBy(dx: dockThickness, dy: 0)
        }
    }

    /// The background plus room for magnified icons, in screen coordinates.
    public var dockRect: CGRect {
        let depth = dockThickness + growth
        switch edge {
        case .bottom: return CGRect(x: frame.minX + margin, y: frame.minY, width: dockLength, height: depth)
        case .left: return CGRect(x: frame.minX, y: frame.minY + margin, width: depth, height: dockLength)
        case .right: return CGRect(x: frame.maxX - depth, y: frame.minY + margin, width: depth, height: dockLength)
        }
    }

    /// Whether the pointer is at this monitor's edge, next to the Dock. A point beyond the edge
    /// (on a neighbouring monitor) does not count.
    public func revealsDock(pointer p: CGPoint) -> Bool {
        let d = Self.revealDistance
        let r = dockRect
        switch edge {
        case .bottom: return p.y >= screen.minY && p.y <= screen.minY + d && p.x >= r.minX && p.x <= r.maxX
        case .left: return p.x >= screen.minX && p.x <= screen.minX + d && p.y >= r.minY && p.y <= r.maxY
        case .right: return p.x <= screen.maxX && p.x >= screen.maxX - d && p.y >= r.minY && p.y <= r.maxY
        }
    }

    /// Whether the panel should take the mouse with the pointer here. Everywhere else (the room for labels and
    /// magnified icons, other monitors, a hidden auto-hide Dock) clicks go to whatever is underneath.
    public func acceptsMouse(pointer p: CGPoint, hidden: Bool) -> Bool {
        !hidden && dockRect.contains(p)
    }

    // MARK: View coordinates

    /// Converts a position along and across the edge into a point in the panel (top-left origin).
    public func point(along: CGFloat, across: CGFloat) -> CGPoint {
        switch edge {
        case .bottom: return CGPoint(x: along, y: frame.height - across)
        case .left: return CGPoint(x: across, y: along)
        case .right: return CGPoint(x: frame.width - across, y: along)
        }
    }

    /// Centre of the background.
    public var dockCenter: CGPoint { point(along: margin + dockLength / 2, across: dockThickness / 2) }

    /// Centre of an item along the edge.
    public func center(ofItem index: Int) -> CGFloat {
        margin + pad + CGFloat(index) * slot + iconSize / 2
    }

    /// The along-position of a pointer in the panel (top-left origin), or `nil` when it is not over the Dock.
    public func hoverAlong(_ p: CGPoint) -> CGFloat? {
        let along = edge == .bottom ? p.x : p.y
        let across: CGFloat
        switch edge {
        case .bottom: across = frame.height - p.y
        case .left: across = p.x
        case .right: across = frame.width - p.x
        }
        guard across >= 0, across <= dockThickness + growth, along >= margin, along <= margin + dockLength else { return nil }
        return along
    }

    /// The item under an along-position.
    public func item(atAlong along: CGFloat) -> Int? {
        let index = Int(((along - margin - pad / 2) / slot).rounded(.down))
        return (0..<itemCount).contains(index) ? index : nil
    }

    /// Icon scale for magnification: largest under the pointer, back to 1 two slots away.
    public func scale(ofItem index: Int, hoverAlong: CGFloat?) -> CGFloat {
        guard magnification, let hoverAlong else { return 1 }
        let distance = abs(hoverAlong - center(ofItem: index)) / (slot * 2)
        guard distance < 1 else { return 1 }
        return 1 + (Self.maxMagnification - 1) * (cos(distance * .pi) + 1) / 2
    }
}
