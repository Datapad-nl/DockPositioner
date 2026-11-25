import ApplicationServices
import DockPositionerCore
import Foundation

/// Reads the badges of the system Dock's apps through Accessibility (each Dock item's `AXStatusLabel`),
/// or `nil` when the Dock cannot be read, for example while it restarts. Blocks while the Dock answers,
/// so it is called off the main thread.
func readSystemDockBadges(dockPID: pid_t) -> [BadgedDockEntry]? {
    let dock = AXUIElementCreateApplication(dockPID)
    AXUIElementSetMessagingTimeout(dock, 0.5)
    guard let children: [AXUIElement] = attribute(dock, kAXChildrenAttribute),
          let list = children.first(where: { attribute($0, kAXRoleAttribute) == kAXListRole as String }),
          let tiles: [AXUIElement] = attribute(list, kAXChildrenAttribute)
    else { return nil }
    // Only the badge is read from every tile; the rest only from tiles that have one.
    return tiles.compactMap { tile in
        AXUIElementSetMessagingTimeout(tile, 0.5)
        guard let badge: String = attribute(tile, "AXStatusLabel"), !badge.isEmpty,
              attribute(tile, kAXSubroleAttribute) == "AXApplicationDockItem"
        else { return nil }
        return BadgedDockEntry(title: attribute(tile, kAXTitleAttribute) ?? "",
                               url: attribute(tile, kAXURLAttribute), badge: badge)
    }
}

private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}
