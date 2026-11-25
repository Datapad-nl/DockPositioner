import Foundation

/// An app in the system Dock that shows a badge, as read through Accessibility.
public struct BadgedDockEntry: Equatable, Sendable {
    public let title: String
    public let url: URL?
    public let badge: String

    public init(title: String, url: URL?, badge: String) {
        self.title = title
        self.url = url
        self.badge = badge
    }
}

/// The badges by item id: an entry goes to the app at the same location, else to the app with the same name.
public func badges(of entries: [BadgedDockEntry], for items: [DockItem]) -> [String: String] {
    let apps = items.filter { $0.kind == .app }
    var result: [String: String] = [:]
    for entry in entries where !entry.badge.isEmpty {
        let path = entry.url?.standardizedFileURL.path
        guard let item = apps.first(where: { $0.url.standardizedFileURL.path == path })
            ?? apps.first(where: { $0.label == entry.title })
        else { continue }
        result[item.id] = entry.badge
    }
    return result
}

/// The items whose icon should bounce when the badges change from `old` to `new` (by item id): a badge that
/// appears, or a number that goes up. `old` is `nil` for the first badges read, which never bounce.
/// The frontmost app (`frontmost`, an item id) does not bounce.
public func itemsToBounce(from old: [String: String]?, to new: [String: String], frontmost: String?) -> Set<String> {
    guard let old else { return [] }
    var result: Set<String> = []
    for (id, badge) in new where id != frontmost {
        guard let previous = old[id] else {
            result.insert(id)
            continue
        }
        if let count = badgeCount(badge), let previousCount = badgeCount(previous), count > previousCount {
            result.insert(id)
        }
    }
    return result
}

/// The number on a badge such as "3", "1,204" or "99+", or `nil` when it is not a number (such as "•").
func badgeCount(_ badge: String) -> Int? {
    var digits = badge.filter { !",. \u{00A0}\u{202F}".contains($0) }
    if digits.hasSuffix("+") { digits.removeLast() }
    return Int(digits)
}
