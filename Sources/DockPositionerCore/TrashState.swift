import Foundation

/// Whether a Trash folder holds items, judged only from its link count (the app cannot list the folder).
/// On APFS a directory's link count is 2 plus its number of entries. `hasDSStore` says whether a
/// `.DS_Store` is known to be among them; when the app cannot stat inside the folder it passes false.
public func trashHasItems(linkCount: Int?, hasDSStore: Bool) -> Bool {
    guard let linkCount else { return false }
    let entries = linkCount - 2 - (hasDSStore ? 1 : 0)
    return entries > 0
}
