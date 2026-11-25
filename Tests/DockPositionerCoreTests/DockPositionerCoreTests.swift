import CoreGraphics
import DockPositionerCore
import Foundation
import Testing

let monitorA = "11111111-1111-1111-1111-111111111111"
let monitorB = "22222222-2222-2222-2222-222222222222"
let leftSettings = DockSettings(position: .left, autoHide: true, magnification: false, size: 0.3)

/// A throwaway UserDefaults domain.
func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "DockPositionerTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@Suite struct ProfileStoreTests {
    @Test func roundTripKeepsDisconnectedMonitors() throws {
        try withDefaults { defaults in
            let profiles = [
                monitorA: MonitorProfile(isEnabled: true, settings: leftSettings),
                // B is not connected right now; its profile must survive.
                monitorB: MonitorProfile(isEnabled: false, settings: .default),
            ]
            ProfileStore(defaults: defaults).save(profiles)
            #expect(ProfileStore(defaults: defaults).load() == profiles)
        }
    }

    @Test func emptyStoreLoadsNothing() throws {
        try withDefaults { defaults in
            #expect(ProfileStore(defaults: defaults).load().isEmpty)
        }
    }

    @Test func loadsProfilesSavedByEarlierVersions() throws {
        try withDefaults { defaults in
            let json = #"{"\#(monitorA)":{"isEnabled":true,"settings":{"size":0.4375,"position":"bottom","autoHide":false,"magnification":true}}}"#
            defaults.set(Data(json.utf8), forKey: "profiles")
            let settings = DockSettings(position: .bottom, autoHide: false, magnification: true, size: 0.4375)
            #expect(ProfileStore(defaults: defaults).load() == [monitorA: MonitorProfile(isEnabled: true, settings: settings)])
        }
    }
}

@Suite struct DockLayoutTests {
    // The user's monitors: a main one, and one to the left of it.
    let main = CGRect(x: 0, y: 0, width: 2855, height: 1195)
    let side = CGRect(x: -1664, y: -677, width: 1664, height: 1872)

    func settings(_ position: DockPosition, size: Double = 0.4, magnification: Bool = false) -> DockSettings {
        DockSettings(position: position, autoHide: false, magnification: magnification, size: size)
    }

    @Test func sizeMapsToIconPoints() {
        #expect(DockLayout.iconSize(forSize: 0) == 16)
        #expect(DockLayout.iconSize(forSize: 1) == 128)
        #expect(DockLayout.iconSize(forSize: 0.5) == 72)
        #expect(DockLayout.iconSize(forSize: 2) == 128)
    }

    @Test func leftDockSitsOnLeftEdgeBelowMenuBar() {
        let layout = DockLayout(settings: settings(.left), itemCount: 12, screen: main, topInset: 30)
        let frame = layout.frame
        #expect(frame.minX == main.minX)
        #expect(main.contains(frame))
        #expect(abs(frame.midY - (main.minY + main.maxY - 30) / 2) <= 0.5)
        #expect(frame.height == layout.dockLength)  // no magnification: no extra room along the edge
        #expect(layout.dockRect.minX == main.minX)
    }

    @Test func bottomDockSitsOnBottomEdgeOfItsOwnMonitor() {
        let layout = DockLayout(settings: settings(.bottom), itemCount: 12, screen: side)
        let frame = layout.frame
        #expect(frame.minY == side.minY)
        #expect(abs(frame.midX - side.midX) <= 0.5)
        #expect(side.contains(frame))
        #expect(frame.width > frame.height)
    }

    @Test func rightDockSitsOnRightEdge() {
        let layout = DockLayout(settings: settings(.right), itemCount: 5, screen: side)
        #expect(layout.frame.maxX == side.maxX)
        #expect(layout.dockRect.maxX == side.maxX)
        #expect(side.contains(layout.frame))
    }

    @Test func iconsShrinkToFitTheMonitor() {
        let layout = DockLayout(settings: settings(.left, size: 1), itemCount: 40, screen: main, topInset: 30)
        #expect(layout.iconSize < 128)
        #expect(layout.frame.height <= main.height - 30)
        #expect(layout.frame.minY >= main.minY)
    }

    @Test func magnificationMakesRoomAwayFromTheEdge() {
        let plain = DockLayout(settings: settings(.bottom), itemCount: 5, screen: main)
        let magnified = DockLayout(settings: settings(.bottom, magnification: true), itemCount: 5, screen: main)
        #expect(magnified.frame.height > plain.frame.height)
        #expect(magnified.dockThickness == plain.dockThickness)
    }

    @Test func hiddenFrameSlidesOffTheEdge() {
        let left = DockLayout(settings: settings(.left), itemCount: 5, screen: main)
        #expect(left.hiddenFrame.minX == left.frame.minX - left.dockThickness)
        let bottom = DockLayout(settings: settings(.bottom), itemCount: 5, screen: side)
        #expect(bottom.hiddenFrame.minY == bottom.frame.minY - bottom.dockThickness)
    }

    @Test func pointerAtTheEdgeRevealsButNotOnTheNeighbour() {
        let layout = DockLayout(settings: settings(.left), itemCount: 5, screen: main)
        let y = layout.frame.midY
        #expect(layout.revealsDock(pointer: CGPoint(x: 0, y: y)))
        #expect(layout.revealsDock(pointer: CGPoint(x: 2.5, y: y)))
        #expect(!layout.revealsDock(pointer: CGPoint(x: 10, y: y)))
        #expect(!layout.revealsDock(pointer: CGPoint(x: -1, y: y)))  // on the monitor to the left
        #expect(!layout.revealsDock(pointer: CGPoint(x: 0, y: main.maxY - 1)))  // beyond the Dock's ends
    }

    @Test func hoverFindsItemsAndMagnifies() throws {
        let layout = DockLayout(settings: settings(.bottom, magnification: true), itemCount: 5, screen: main)
        let center = layout.center(ofItem: 2)
        let inside = layout.point(along: center, across: layout.dockThickness / 2)
        let along = try #require(layout.hoverAlong(inside))
        #expect(layout.item(atAlong: along) == 2)
        #expect(layout.scale(ofItem: 2, hoverAlong: along) == DockLayout.maxMagnification)
        #expect(layout.scale(ofItem: 1, hoverAlong: along) > 1)
        #expect(layout.scale(ofItem: 0, hoverAlong: along) == 1)
        #expect(layout.scale(ofItem: 2, hoverAlong: nil) == 1)
        // In the label area above the icons the pointer is not over the Dock.
        #expect(layout.hoverAlong(CGPoint(x: inside.x, y: 0)) == nil)
    }

    @Test func leftDockTakesTheMouseOnlyInsideTheDock() {
        let layout = DockLayout(settings: settings(.left, magnification: true), itemCount: 12, screen: main, topInset: 30)
        let y = layout.dockRect.midY
        #expect(layout.frame.width > layout.dockRect.width + 150)  // the margin is wide
        #expect(layout.acceptsMouse(pointer: CGPoint(x: 10, y: y), hidden: false))
        // In the label and magnification room next to the Dock, still inside the panel.
        let margin = CGPoint(x: layout.dockRect.maxX + 20, y: y)
        #expect(layout.frame.contains(margin))
        #expect(!layout.acceptsMouse(pointer: margin, hidden: false))
        #expect(!layout.acceptsMouse(pointer: CGPoint(x: -10, y: y), hidden: false))  // on the monitor to the left
        #expect(!layout.acceptsMouse(pointer: CGPoint(x: 10, y: y), hidden: true))  // hidden auto-hide Dock
    }

    @Test func bottomDockTakesTheMouseOnlyInsideTheDock() {
        let layout = DockLayout(settings: settings(.bottom, magnification: true), itemCount: 12, screen: side)
        let x = layout.dockRect.midX
        #expect(layout.acceptsMouse(pointer: CGPoint(x: x, y: side.minY + 5), hidden: false))
        let above = CGPoint(x: x, y: layout.dockRect.maxY + 10)
        #expect(layout.frame.contains(above))
        #expect(!layout.acceptsMouse(pointer: above, hidden: false))
        let end = CGPoint(x: layout.dockRect.minX - 20, y: side.minY + 5)  // room beyond the end icon
        #expect(layout.frame.contains(end))
        #expect(!layout.acceptsMouse(pointer: end, hidden: false))
        #expect(!layout.acceptsMouse(pointer: CGPoint(x: 100, y: 5), hidden: false))  // on the main monitor
        #expect(!layout.acceptsMouse(pointer: CGPoint(x: x, y: side.minY + 5), hidden: true))
    }

    @Test func noMagnificationWhenSwitchedOff() {
        let layout = DockLayout(settings: settings(.bottom), itemCount: 5, screen: main)
        #expect(layout.scale(ofItem: 2, hoverAlong: layout.center(ofItem: 2)) == 1)
    }
}

@Suite struct DockItemTests {
    let finder = DockItem(kind: .app, url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                          label: "Finder", bundleID: "com.apple.finder")
    let trash = DockItem(kind: .trash, url: URL(fileURLWithPath: "/Users/me/.Trash"), label: "Trash")

    func tile(_ url: String, label: String, bundleID: String? = nil, urlType: Int = 15) -> [String: Any] {
        var data: [String: Any] = ["file-data": ["_CFURLString": url, "_CFURLStringType": urlType], "file-label": label]
        data["bundle-identifier"] = bundleID
        return ["tile-data": data, "tile-type": "file-tile"]
    }

    @Test func parsesPinnedAppsAndSkipsSpacers() {
        let entries: [Any] = [
            tile("file:///Applications/Safari.app/", label: "Safari", bundleID: "com.apple.Safari"),
            ["tile-data": [:] as [String: Any], "tile-type": "spacer-tile"],
            tile("/Applications/Notes.app", label: "Notes", urlType: 0),
            "garbage",
        ]
        let items = dockItems(fromPreference: entries, kind: .app)
        #expect(items.map(\.label) == ["Safari", "Notes"])
        #expect(items[0].url.path == "/Applications/Safari.app")
        #expect(items[0].bundleID == "com.apple.Safari")
        #expect(items[1].url.path == "/Applications/Notes.app")
        #expect(dockItems(fromPreference: nil, kind: .app).isEmpty)
    }

    @Test func parsesFolders() {
        let items = dockItems(fromPreference: [tile("file:///Users/me/Downloads/", label: "Downloads")], kind: .folder)
        #expect(items == [DockItem(kind: .folder, url: URL(string: "file:///Users/me/Downloads/")!, label: "Downloads")])
    }

    @Test func mergesInDockOrderWithoutDuplicates() {
        let safari = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Safari.app"), label: "Safari", bundleID: "com.apple.Safari")
        let notes = DockItem(kind: .app, url: URL(string: "file:///Applications/Notes.app/")!, label: "Notes")
        let xcode = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Xcode.app"), label: "Xcode", bundleID: "com.apple.dt.Xcode")
        let runningNotes = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Notes.app"), label: "Notes", bundleID: "com.apple.Notes")
        let downloads = DockItem(kind: .folder, url: URL(fileURLWithPath: "/Users/me/Downloads"), label: "Downloads")

        let items = mergedDockItems(
            finder: finder,
            pinned: [safari, notes],
            running: [finder, xcode, safari, runningNotes],
            others: [downloads],
            trash: trash
        )
        #expect(items.map(\.label) == ["Finder", "Safari", "Notes", "Xcode", "Downloads", "Trash"])
    }
}

@Suite struct SystemDockHiderTests {
    final class Restarts: @unchecked Sendable { var count = 0 }

    @Test func hideThenRestorePutsValuesBackExactly() throws {
        try withDefaults { dock in
            try withDefaults { store in
                dock.set(false, forKey: "autohide")
                dock.set(0.5, forKey: "autohide-delay")
                let restarts = Restarts()
                let hider = SystemDockHider(dock: dock, store: store) { restarts.count += 1 }

                hider.hide()
                #expect(dock.object(forKey: "autohide") as? Bool == true)
                #expect(dock.double(forKey: "autohide-delay") == SystemDockHider.hiddenDelay)
                #expect(hider.isHidden)

                hider.restore()
                #expect(dock.object(forKey: "autohide") as? Bool == false)
                #expect(dock.object(forKey: "autohide-delay") as? Double == 0.5)
                #expect(!hider.isHidden)
                #expect(restarts.count == 2)
            }
        }
    }

    @Test func absentKeysAreAbsentAgainAfterRestore() throws {
        try withDefaults { dock in
            try withDefaults { store in
                let hider = SystemDockHider(dock: dock, store: store) {}
                hider.hide()
                #expect(dock.object(forKey: "autohide-delay") != nil)
                hider.restore()
                #expect(dock.object(forKey: "autohide") == nil)
                #expect(dock.object(forKey: "autohide-delay") == nil)
            }
        }
    }

    @Test func hidingAgainKeepsTheOriginalValues() throws {
        try withDefaults { dock in
            try withDefaults { store in
                dock.set(false, forKey: "autohide")
                // E.g. a relaunch after a crash while hidden: the Dock still has our values.
                SystemDockHider(dock: dock, store: store) {}.hide()
                SystemDockHider(dock: dock, store: store) {}.hide()
                SystemDockHider(dock: dock, store: store) {}.restore()
                #expect(dock.object(forKey: "autohide") as? Bool == false)
                #expect(dock.object(forKey: "autohide-delay") == nil)
            }
        }
    }

    @Test func restoreWithoutHideChangesNothing() throws {
        try withDefaults { dock in
            try withDefaults { store in
                dock.set(true, forKey: "autohide")
                let restarts = Restarts()
                SystemDockHider(dock: dock, store: store) { restarts.count += 1 }.restore()
                #expect(dock.object(forKey: "autohide") as? Bool == true)
                #expect(restarts.count == 0)
            }
        }
    }
}

@Suite struct WindowFitTests {
    // The user's monitors (AppKit coordinates): LG ULTRAGEAR+ with a Left Dock, and LG SDQHD to its left with a Bottom Dock.
    let main = CGRect(x: 0, y: 0, width: 2855, height: 1195)
    let side = CGRect(x: -1664, y: -677, width: 1664, height: 1872)
    let thickness: CGFloat = 80

    @Test func flushLeftEdgeMovesRight() {
        let window = CGRect(x: 0, y: 0, width: 1400, height: 1165)
        let fixed = frameClearOfDock(window: window, screen: main, edge: .left, dockThickness: thickness)
        #expect(fixed == CGRect(x: 80, y: 0, width: 1320, height: 1165))
    }

    @Test func flushRightEdgeMovesLeft() {
        let window = CGRect(x: 1455, y: 0, width: 1400.5, height: 1165)  // within 2 pt of the edge
        let fixed = frameClearOfDock(window: window, screen: main, edge: .right, dockThickness: thickness)
        #expect(fixed == CGRect(x: 1455, y: 0, width: 1320, height: 1165))
    }

    @Test func flushBottomEdgeMovesUpOnTheSideMonitor() {
        let window = CGRect(x: -1664, y: -677, width: 1664, height: 1842)  // zoomed: the whole monitor below the menu bar
        let fixed = frameClearOfDock(window: window, screen: side, edge: .bottom, dockThickness: thickness)
        #expect(fixed == CGRect(x: -1664, y: -597, width: 1664, height: 1762))
    }

    @Test func overlappingButNotFlushIsLeftAlone() {
        let dragged = CGRect(x: 30, y: 100, width: 800, height: 600)
        #expect(frameClearOfDock(window: dragged, screen: main, edge: .left, dockThickness: thickness) == nil)
        let offScreen = CGRect(x: -1664, y: -900, width: 800, height: 600)
        #expect(frameClearOfDock(window: offScreen, screen: side, edge: .bottom, dockThickness: thickness) == nil)
    }

    @Test func windowOnTheOtherMonitorIsLeftAlone() {
        // Maximised on the side monitor; its right edge touches the main monitor's left edge.
        let window = CGRect(x: -1664, y: -677, width: 1664, height: 1842)
        #expect(frameClearOfDock(window: window, screen: main, edge: .left, dockThickness: thickness) == nil)
        #expect(frameClearOfDock(window: window, screen: main, edge: .right, dockThickness: thickness) == nil)
    }

    @Test func correctedWindowIsNotCorrectedAgain() throws {
        let layoutThickness = DockLayout(settings: .default, itemCount: 12, screen: main).dockThickness
        for (screen, edge) in [(main, DockPosition.left), (main, .right), (side, .bottom)] {
            let fixed = try #require(frameClearOfDock(window: screen, screen: screen, edge: edge, dockThickness: layoutThickness))
            #expect(frameClearOfDock(window: fixed, screen: screen, edge: edge, dockThickness: layoutThickness) == nil)
        }
    }

    @Test func flipsBetweenAppKitAndAccessibilityCoordinates() {
        let primaryHeight = main.height
        // Both monitors' tops are at AppKit y = 1195, so both start at the top in Accessibility coordinates.
        #expect(flipped(main, primaryHeight: primaryHeight) == CGRect(x: 0, y: 0, width: 2855, height: 1195))
        #expect(flipped(side, primaryHeight: primaryHeight) == CGRect(x: -1664, y: 0, width: 1664, height: 1872))
        let window = CGRect(x: -1664, y: -597, width: 1664, height: 1762)
        #expect(flipped(window, primaryHeight: primaryHeight) == CGRect(x: -1664, y: 30, width: 1664, height: 1762))
        #expect(flipped(flipped(window, primaryHeight: primaryHeight), primaryHeight: primaryHeight) == window)
    }
}

@Suite struct PinningTests {
    static func tile(_ url: String, label: String) -> [String: Any] {
        ["tile-data": ["file-data": ["_CFURLString": url, "_CFURLStringType": 15], "file-label": label,
                       "GUID": 12345, "file-mod-date": 3_700_000_000] as [String: Any],
         "tile-type": "file-tile"]
    }

    let sample: [Any] = [
        tile("file:///Applications/Safari.app/", label: "Safari"),
        ["tile-data": [:] as [String: Any], "tile-type": "spacer-tile"],
        tile("file:///Applications/Visual%20Studio%20Code.app/", label: "Visual Studio Code"),
        tile("file:///System/Applications/Notes.app/", label: "Notes"),
    ]

    /// Plist bytes of one entry (XML: keys sorted), to show it is left exactly as it was.
    func bytes(_ entry: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entry, format: .xml, options: 0)
    }

    @Test func addsAnEntryOfTheDocksShape() throws {
        let url = URL(fileURLWithPath: "/Applications/My App.app")
        let entries = addingDockEntry(to: sample, appURL: url, label: "My App", bundleID: "com.example.MyApp")
        #expect(entries.count == sample.count + 1)
        for (old, new) in zip(sample, entries) { #expect(try bytes(old) == bytes(new)) }

        let added = try #require(entries.last as? [String: Any])
        #expect(added["tile-type"] as? String == "file-tile")
        let tile = try #require(added["tile-data"] as? [String: Any])
        #expect(tile["file-label"] as? String == "My App")
        #expect(tile["bundle-identifier"] as? String == "com.example.MyApp")
        #expect(tile["file-type"] as? Int == 41)
        let file = try #require(tile["file-data"] as? [String: Any])
        #expect(file["_CFURLString"] as? String == "file:///Applications/My%20App.app/")
        #expect(file["_CFURLStringType"] as? Int == 15)
        // The Dock and this app read it back as the same app.
        #expect(dockItems(fromPreference: entries, kind: .app).last?.url.standardizedFileURL.path == url.path)
    }

    @Test func addsWithoutBundleIdentifierWhenUnknown() throws {
        let entries = addingDockEntry(to: [], appURL: URL(fileURLWithPath: "/Applications/Tool.app"), label: "Tool", bundleID: nil)
        let tile = try #require((entries.first as? [String: Any])?["tile-data"] as? [String: Any])
        #expect(tile["bundle-identifier"] == nil)
    }

    @Test func doesNotAddTwice() throws {
        let entries = addingDockEntry(to: sample, appURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
                                      label: "Code", bundleID: nil)
        #expect(entries.count == sample.count)
        for (old, new) in zip(sample, entries) { #expect(try bytes(old) == bytes(new)) }
    }

    @Test func removesByURLIncludingAPercentEncodedPathWithASpace() throws {
        let entries = removingDockEntry(from: sample, appURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"))
        #expect(entries.count == sample.count - 1)
        let kept = [sample[0], sample[1], sample[3]]
        for (old, new) in zip(kept, entries) { #expect(try bytes(old) == bytes(new)) }
        // A URL with a trailing slash finds it as well.
        let again = removingDockEntry(from: sample, appURL: URL(string: "file:///Applications/Visual%20Studio%20Code.app/")!)
        #expect(again.count == sample.count - 1)
    }

    @Test func removingAnAppThatIsNotThereChangesNothing() throws {
        let entries = removingDockEntry(from: sample, appURL: URL(fileURLWithPath: "/Applications/Xcode.app"))
        #expect(entries.count == sample.count)
        for (old, new) in zip(sample, entries) { #expect(try bytes(old) == bytes(new)) }
    }
}

@Suite struct DockMenuTests {
    let safari = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Safari.app"), label: "Safari", bundleID: "com.apple.Safari")
    let finder = DockItem(kind: .app, url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                          label: "Finder", bundleID: finderBundleID)
    let windows = [DockWindowInfo(title: "Start"), DockWindowInfo(title: ""), DockWindowInfo(title: "Docs", isMinimized: true)]

    @Test func runningPinnedTrustedApp() {
        let menu = dockMenu(for: safari, context: DockMenuContext(isRunning: true, isPinned: true, isTrusted: true, windows: windows))
        #expect(menu == [
            .window(title: "Start", index: 0, isMinimized: false),
            .window(title: "Docs", index: 2, isMinimized: true),  // the untitled window is skipped
            .separator,
            .submenu("Options", [.action("Keep in Dock", .unpin, isChecked: true), .action("Show in Finder", .showInFinder)]),
            .separator,
            .action("Hide", .hide),
            .action("Quit", .quit),
        ])
    }

    @Test func runningUnpinnedHiddenAppWithOptionHeld() {
        let menu = dockMenu(for: safari, context: DockMenuContext(isRunning: true, isHidden: true, isTrusted: true, optionHeld: true))
        #expect(menu == [
            .submenu("Options", [.action("Keep in Dock", .pin), .action("Show in Finder", .showInFinder)]),
            .separator,
            .action("Show", .unhide),
            .action("Force Quit", .forceQuit),
        ])
    }

    @Test func noWindowsWithoutAccessibility() {
        let menu = dockMenu(for: safari, context: DockMenuContext(isRunning: true, isTrusted: false, windows: windows))
        #expect(menu.first == .submenu("Options", [.action("Keep in Dock", .pin), .action("Show in Finder", .showInFinder)]))
        #expect(!menu.contains { if case .window = $0 { true } else { false } })
    }

    @Test func pinnedAppThatIsNotRunning() {
        let menu = dockMenu(for: safari, context: DockMenuContext(isPinned: true, isTrusted: true, optionHeld: true))
        #expect(menu == [
            .action("Open", .open),
            .separator,
            .submenu("Options", [.action("Remove from Dock", .unpin), .action("Show in Finder", .showInFinder)]),
        ])
    }

    @Test func finderNeitherPinsNorQuits() {
        let menu = dockMenu(for: finder, context: DockMenuContext(isRunning: true, isTrusted: true, optionHeld: true,
                                                                  windows: [DockWindowInfo(title: "Downloads")]))
        #expect(menu == [
            .window(title: "Downloads", index: 0, isMinimized: false),
            .separator,
            .submenu("Options", [.action("Show in Finder", .showInFinder)]),
            .separator,
            .action("Hide", .hide),
        ])
    }

    @Test func folderAndTrash() {
        let folder = DockItem(kind: .folder, url: URL(fileURLWithPath: "/Users/me/Downloads"), label: "Downloads")
        let trash = DockItem(kind: .trash, url: URL(fileURLWithPath: "/Users/me/.Trash"), label: "Trash")
        let context = DockMenuContext(isRunning: true, isTrusted: true, optionHeld: true)
        #expect(dockMenu(for: folder, context: context) == [.action("Open", .open), .action("Show in Finder", .showInFinder)])
        #expect(dockMenu(for: trash, context: context) == [.action("Open", .open), .action("Empty Trash", .emptyTrash)])
    }
}

@Suite struct TrashStateTests {
    @Test func emptyFolder() { #expect(!trashHasItems(linkCount: 2, hasDSStore: false)) }
    @Test func onlyDSStore() { #expect(!trashHasItems(linkCount: 3, hasDSStore: true)) }
    @Test func oneItemWithoutDSStore() { #expect(trashHasItems(linkCount: 3, hasDSStore: false)) }
    @Test func manyItems() {
        #expect(trashHasItems(linkCount: 10, hasDSStore: true))
        #expect(trashHasItems(linkCount: 10, hasDSStore: false))
    }
    @Test func missingFolder() { #expect(!trashHasItems(linkCount: nil, hasDSStore: false)) }
}


@Suite struct BadgeTests {
    let outlook = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Microsoft Outlook.app"),
                           label: "Microsoft Outlook", bundleID: "com.microsoft.Outlook")
    let telegram = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Telegram.app"), label: "Telegram")
    let downloads = DockItem(kind: .folder, url: URL(fileURLWithPath: "/Users/me/Downloads"), label: "Downloads")

    @Test func matchesByPercentEncodedURL() throws {
        // The Dock reports a file URL with a trailing slash and percent-encoded spaces.
        let url = try #require(URL(string: "file:///Applications/Microsoft%20Outlook.app/"))
        let entry = BadgedDockEntry(title: "Outlook", url: url, badge: "3")
        #expect(badges(of: [entry], for: [telegram, outlook]) == [outlook.id: "3"])
    }

    @Test func fallsBackToTitle() throws {
        // The app was moved: its location differs, its name does not.
        let url = try #require(URL(string: "file:///Users/me/Applications/Telegram.app/"))
        let moved = BadgedDockEntry(title: "Telegram", url: url, badge: "•")
        let noURL = BadgedDockEntry(title: "Microsoft Outlook", url: nil, badge: "1")
        #expect(badges(of: [moved, noURL], for: [outlook, telegram]) == [telegram.id: "•", outlook.id: "1"])
    }

    @Test func ignoresUnmatchedFoldersAndEmptyBadges() {
        let entries = [
            BadgedDockEntry(title: "Downloads", url: nil, badge: "2"),  // only apps get badges
            BadgedDockEntry(title: "Elsewhere", url: URL(fileURLWithPath: "/Applications/Elsewhere.app"), badge: "1"),
            BadgedDockEntry(title: "Telegram", url: nil, badge: ""),
        ]
        #expect(badges(of: entries, for: [downloads, telegram]).isEmpty)
    }

    @Test func firstSnapshotNeverBounces() {
        #expect(itemsToBounce(from: nil, to: ["a": "3", "b": "•"], frontmost: nil).isEmpty)
    }

    @Test func appearingBadgeBounces() {
        #expect(itemsToBounce(from: [:], to: ["a": "1"], frontmost: nil) == ["a"])
        #expect(itemsToBounce(from: ["b": "2"], to: ["a": "•", "b": "2"], frontmost: nil) == ["a"])
    }

    @Test func risingNumberBounces() {
        #expect(itemsToBounce(from: ["a": "1"], to: ["a": "2"], frontmost: nil) == ["a"])
        #expect(itemsToBounce(from: ["a": "999"], to: ["a": "1,000"], frontmost: nil) == ["a"])
        #expect(itemsToBounce(from: ["a": "9"], to: ["a": "99+"], frontmost: nil) == ["a"])
    }

    @Test func fallingOrSameNumberDoesNotBounce() {
        #expect(itemsToBounce(from: ["a": "5"], to: ["a": "4"], frontmost: nil).isEmpty)
        #expect(itemsToBounce(from: ["a": "5"], to: ["a": "5"], frontmost: nil).isEmpty)
    }

    @Test func disappearingBadgeDoesNotBounce() {
        #expect(itemsToBounce(from: ["a": "5", "b": "•"], to: [:], frontmost: nil).isEmpty)
    }

    @Test func changedTextDoesNotBounce() {
        #expect(itemsToBounce(from: ["a": "•"], to: ["a": "!"], frontmost: nil).isEmpty)
        #expect(itemsToBounce(from: ["a": "3"], to: ["a": "•"], frontmost: nil).isEmpty)
        #expect(itemsToBounce(from: ["a": "•"], to: ["a": "3"], frontmost: nil).isEmpty)
    }

    @Test func frontmostAppDoesNotBounce() {
        let bounce = itemsToBounce(from: ["a": "1"], to: ["a": "2", "b": "1"], frontmost: "a")
        #expect(bounce == ["b"])
    }

    @Test func bounceStaysInsidePanel() {
        let screen = CGRect(x: 0, y: 0, width: 2855, height: 1195)
        for position in DockPosition.allCases {
            for magnification in [false, true] {
                for size in [0.0, 0.5, 1.0] {
                    let settings = DockSettings(position: position, autoHide: false, magnification: magnification, size: size)
                    let layout = DockLayout(settings: settings, itemCount: 12, screen: screen)
                    let largest = layout.iconSize * (magnification ? DockLayout.maxMagnification : 1)
                    let thickness = position == .bottom ? layout.frame.height : layout.frame.width
                    #expect(layout.bounceHeight > 0)
                    #expect(layout.pad + largest + layout.bounceHeight <= thickness)
                }
            }
        }
    }
}

@Suite struct SoundMarkTests {
    let brave = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Brave Browser.app"),
                         label: "Brave Browser", bundleID: "com.brave.Browser")
    let foo = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Foo.app"), label: "Foo", bundleID: "com.foo")
    let fooBar = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Foo Bar.app"), label: "Foo Bar")
    let downloads = DockItem(kind: .folder, url: URL(fileURLWithPath: "/Users/me/Downloads"), label: "Downloads")

    func process(_ path: String?, bundleID: String? = nil, running: Bool = true) -> AudioProcess {
        AudioProcess(pid: 42, executablePath: path, bundleID: bundleID, isRunningOutput: running)
    }

    @Test func helperInsideTheAppBundleCountsForTheApp() {
        let helper = process("/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/"
            + "Versions/1/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper",
            bundleID: "com.brave.Browser.helper")
        #expect(itemsPlayingSound([helper], items: [foo, brave]) == [brave.id])
    }

    @Test func pathThatOnlySharesAPrefixDoesNotMatch() {
        let p = process("/Applications/Foo Bar.app/Contents/MacOS/Foo Bar")
        #expect(itemsPlayingSound([p], items: [foo, fooBar]) == [fooBar.id])
        #expect(itemsPlayingSound([p], items: [foo]).isEmpty)
    }

    @Test func innermostBundleWins() {
        let inner = DockItem(kind: .app, url: URL(fileURLWithPath: "/Applications/Foo.app/Contents/Resources/Inner.app"),
                             label: "Inner")
        let p = process("/Applications/Foo.app/Contents/Resources/Inner.app/Contents/MacOS/Inner")
        #expect(itemsPlayingSound([p], items: [foo, inner]) == [inner.id])
    }

    @Test func fallsBackToBundleIdentifier() {
        #expect(itemsPlayingSound([process("/elsewhere/foo", bundleID: "com.foo")], items: [foo, brave]) == [foo.id])
        #expect(itemsPlayingSound([process(nil, bundleID: "com.foo")], items: [foo]) == [foo.id])
        // Exact match only: a helper's own identifier is not the app's.
        #expect(itemsPlayingSound([process(nil, bundleID: "com.foo.helper")], items: [foo]).isEmpty)
    }

    @Test func notRunningAndUnmatchedAreIgnored() {
        let processes = [
            process("/Applications/Foo.app/Contents/MacOS/Foo", bundleID: "com.foo", running: false),
            process("/usr/bin/afplay"),
            process(nil, bundleID: nil),
            process("/Users/me/Downloads/tool"),  // only apps get marks
        ]
        #expect(itemsPlayingSound(processes, items: [foo, downloads]).isEmpty)
    }

    func changed(_ marks: inout SoundMarks, _ sounding: Set<String>) -> Bool {
        marks.update(sounding: sounding)
    }

    @Test func markStaysUntilQuietForTwoPolls() {
        var marks = SoundMarks()
        #expect(changed(&marks, ["a"]))
        #expect(marks.marked == ["a"])
        #expect(!changed(&marks, []))  // quiet once: kept
        #expect(marks.marked == ["a"])
        #expect(changed(&marks, []))  // quiet twice: gone
        #expect(marks.marked.isEmpty)
        #expect(!changed(&marks, []))
    }

    @Test func soundingAgainResetsTheQuietCount() {
        var marks = SoundMarks()
        _ = marks.update(sounding: ["a", "b"])
        #expect(!changed(&marks, ["b"]))
        #expect(!changed(&marks, ["a", "b"]))  // a blinked; never lost its mark
        #expect(!changed(&marks, ["b"]))  // quiet once again, not twice in a row
        #expect(marks.marked == ["a", "b"])
        #expect(changed(&marks, ["b"]))
        #expect(marks.marked == ["b"])
    }
}
