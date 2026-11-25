import Foundation

/// A process that Core Audio knows as an audio client.
public struct AudioProcess: Equatable, Sendable {
    public let pid: Int32
    /// The process's executable, from `proc_pidpath`; `nil` when it cannot be read.
    public let executablePath: String?
    public let bundleID: String?
    /// Whether the process has an audio output running.
    public let isRunningOutput: Bool

    public init(pid: Int32, executablePath: String?, bundleID: String?, isRunningOutput: Bool) {
        self.pid = pid
        self.executablePath = executablePath
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

/// The ids of the app items that have an audio output running. A process belongs to the app whose bundle
/// folder holds its executable (so a browser's helper counts for the browser; the innermost bundle wins),
/// else to the app with the same bundle identifier. Processes that belong to no item are ignored.
public func itemsPlayingSound(_ processes: [AudioProcess], items: [DockItem]) -> Set<String> {
    let apps = items.filter { $0.kind == .app }
    var result: Set<String> = []
    for process in processes where process.isRunningOutput {
        let inside = process.executablePath.flatMap { path in
            apps.filter { path.hasPrefix(bundleFolder($0)) }.max { bundleFolder($0).count < bundleFolder($1).count }
        }
        let byID = process.bundleID.flatMap { id in apps.first { $0.bundleID == id } }
        if let item = inside ?? byID { result.insert(item.id) }
    }
    return result
}

/// An app's bundle path with a trailing slash, so `/Applications/Foo.app` does not match `/Applications/Foo Bar.app`.
private func bundleFolder(_ item: DockItem) -> String {
    let path = item.url.standardizedFileURL.path
    return path.hasSuffix("/") ? path : path + "/"
}

/// The items that show the speaker mark. An item keeps its mark until it has been quiet for two polls
/// in a row, so an output that closes for a moment does not make the mark flicker.
public struct SoundMarks: Sendable {
    public private(set) var marked: Set<String> = []
    private var quietPolls: [String: Int] = [:]

    public init() {}

    /// Takes one poll's sounding items; returns whether `marked` changed.
    public mutating func update(sounding: Set<String>) -> Bool {
        let before = marked
        for id in sounding {
            marked.insert(id)
            quietPolls[id] = nil
        }
        for id in marked.subtracting(sounding) {
            let quiet = quietPolls[id, default: 0] + 1
            if quiet >= 2 {
                marked.remove(id)
                quietPolls[id] = nil
            } else {
                quietPolls[id] = quiet
            }
        }
        return marked != before
    }
}
