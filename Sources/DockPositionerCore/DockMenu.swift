import Foundation

/// What choosing a menu entry does; the AppKit side carries it out.
public enum DockMenuAction: Equatable, Sendable {
    case open, pin, unpin, showInFinder, hide, unhide, quit, forceQuit, emptyTrash
}

/// One entry of a Dock item's menu.
public enum DockMenuEntry: Equatable, Sendable {
    /// A window of the app; `index` is its position in `DockMenuContext.windows`.
    case window(title: String, index: Int, isMinimized: Bool)
    case action(String, DockMenuAction, isChecked: Bool = false)
    case submenu(String, [DockMenuEntry])
    case separator
}

public struct DockWindowInfo: Equatable, Sendable {
    public let title: String
    public let isMinimized: Bool

    public init(title: String, isMinimized: Bool = false) {
        self.title = title
        self.isMinimized = isMinimized
    }
}

/// What is known about an item when its menu opens.
public struct DockMenuContext: Equatable, Sendable {
    public var isRunning: Bool
    public var isHidden: Bool
    public var isPinned: Bool
    /// Whether this app may use the Accessibility API; without it no windows are listed.
    public var isTrusted: Bool
    public var optionHeld: Bool
    public var windows: [DockWindowInfo]

    public init(isRunning: Bool = false, isHidden: Bool = false, isPinned: Bool = false, isTrusted: Bool = false,
                optionHeld: Bool = false, windows: [DockWindowInfo] = []) {
        self.isRunning = isRunning
        self.isHidden = isHidden
        self.isPinned = isPinned
        self.isTrusted = isTrusted
        self.optionHeld = optionHeld
        self.windows = windows
    }
}

public let finderBundleID = "com.apple.finder"

/// The entries of an item's menu, like the system Dock's as far as public APIs allow.
public func dockMenu(for item: DockItem, context: DockMenuContext) -> [DockMenuEntry] {
    switch item.kind {
    case .trash: return [.action("Open", .open), .action("Empty Trash", .emptyTrash)]
    case .folder: return [.action("Open", .open), .action("Show in Finder", .showInFinder)]
    case .app: break
    }
    let isFinder = item.bundleID == finderBundleID  // Finder always stays in the Dock and running
    guard context.isRunning else {
        let pin: DockMenuEntry = context.isPinned ? .action("Remove from Dock", .unpin) : .action("Keep in Dock", .pin)
        return [.action("Open", .open), .separator,
                .submenu("Options", (isFinder ? [] : [pin]) + [.action("Show in Finder", .showInFinder)])]
    }
    var entries: [DockMenuEntry] = []
    if context.isTrusted {
        for (index, window) in context.windows.enumerated() where !window.title.isEmpty {
            entries.append(.window(title: window.title, index: index, isMinimized: window.isMinimized))
        }
        if !entries.isEmpty { entries.append(.separator) }
    }
    var options: [DockMenuEntry] = []
    if !isFinder {
        options.append(.action("Keep in Dock", context.isPinned ? .unpin : .pin, isChecked: context.isPinned))
    }
    options.append(.action("Show in Finder", .showInFinder))
    entries += [.submenu("Options", options), .separator,
                context.isHidden ? .action("Show", .unhide) : .action("Hide", .hide)]
    if !isFinder {
        entries.append(context.optionHeld ? .action("Force Quit", .forceQuit) : .action("Quit", .quit))
    }
    return entries
}

// MARK: Pinning

/// The file URL of an entry of the system Dock's `persistent-apps` or `persistent-others` preference.
func dockEntryURL(_ entry: Any) -> URL? {
    guard let tile = (entry as? [String: Any])?["tile-data"] as? [String: Any],
          let file = tile["file-data"] as? [String: Any],
          let string = file["_CFURLString"] as? String
    else { return nil }
    // _CFURLStringType 0 is a plain path, 15 a URL string.
    let url = (file["_CFURLStringType"] as? Int) == 0 ? URL(fileURLWithPath: string) : URL(string: string)
    guard let url, url.isFileURL else { return nil }
    return url
}

private func isEntry(_ entry: Any, for appURL: URL) -> Bool {
    dockEntryURL(entry)?.standardizedFileURL.path == appURL.standardizedFileURL.path
}

/// `persistent-apps` with an entry for the app at `appURL` added at the end, unless it is there already.
public func addingDockEntry(to entries: [Any], appURL: URL, label: String, bundleID: String?) -> [Any] {
    guard !entries.contains(where: { isEntry($0, for: appURL) }) else { return entries }
    let fileData: [String: Any] = [
        "_CFURLString": URL(fileURLWithPath: appURL.standardizedFileURL.path, isDirectory: true).absoluteString,
        "_CFURLStringType": 15,
    ]
    var tileData: [String: Any] = ["file-label": label, "file-type": 41, "file-data": fileData]
    tileData["bundle-identifier"] = bundleID
    return entries + [["tile-type": "file-tile", "tile-data": tileData] as [String: Any]]
}

/// `persistent-apps` without the entries for the app at `appURL`; all other entries are kept as they are.
public func removingDockEntry(from entries: [Any], appURL: URL) -> [Any] {
    entries.filter { !isEntry($0, for: appURL) }
}
