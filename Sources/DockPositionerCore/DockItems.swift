import Foundation

/// Something shown in the Dock: an app, a folder from the system Dock's right side, or the Trash.
public struct DockItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case app, folder, trash
    }

    public let kind: Kind
    public let url: URL
    public let label: String
    public let bundleID: String?

    public init(kind: Kind, url: URL, label: String, bundleID: String? = nil) {
        self.kind = kind
        self.url = url
        self.label = label
        self.bundleID = bundleID
    }

    public var id: String { "\(kind.rawValue):\(url.standardizedFileURL.path)" }

    /// Same app: by bundle identifier when both have one, else by location.
    public func isSameApp(as other: DockItem) -> Bool {
        if let bundleID, let otherID = other.bundleID { return bundleID == otherID }
        return url.standardizedFileURL.path == other.url.standardizedFileURL.path
    }
}

/// Reads the entries of the system Dock's `persistent-apps` or `persistent-others` preference.
/// Entries without a file (such as spacers) are skipped.
public func dockItems(fromPreference entries: [Any]?, kind: DockItem.Kind) -> [DockItem] {
    (entries ?? []).compactMap { entry in
        guard let url = dockEntryURL(entry), let tile = (entry as? [String: Any])?["tile-data"] as? [String: Any]
        else { return nil }
        let label = tile["file-label"] as? String ?? url.deletingPathExtension().lastPathComponent
        return DockItem(kind: kind, url: url, label: label, bundleID: tile["bundle-identifier"] as? String)
    }
}

/// The Dock's items in order: Finder, pinned apps, running apps that are not pinned, folders, Trash.
public func mergedDockItems(
    finder: DockItem, pinned: [DockItem], running: [DockItem], others: [DockItem], trash: DockItem
) -> [DockItem] {
    var apps = [finder]
    for app in pinned + running where !apps.contains(where: { $0.isSameApp(as: app) }) {
        apps.append(app)
    }
    return apps + others + [trash]
}
