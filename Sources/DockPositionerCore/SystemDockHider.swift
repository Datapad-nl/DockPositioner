import Foundation

/// Hides the system Dock by letting it auto-hide with a delay so long that it never comes back,
/// and puts the user's own values back. The original values stay in `store` until restored,
/// so they survive a crash or a relaunch.
public struct SystemDockHider {
    public static let keys = ["autohide", "autohide-delay"]
    public static let hiddenDelay = 1000.0
    private static let savedKey = "savedSystemDockValues"

    private let dock: UserDefaults
    private let store: UserDefaults
    private let restartDock: () -> Void

    /// `dock` is the `com.apple.dock` domain; `store` is where the original values are kept.
    public init(dock: UserDefaults, store: UserDefaults, restartDock: @escaping () -> Void) {
        self.dock = dock
        self.store = store
        self.restartDock = restartDock
    }

    /// Whether original values are saved, i.e. the Dock is (or was left) hidden by this app.
    public var isHidden: Bool { store.dictionary(forKey: Self.savedKey) != nil }

    public func hide() {
        // Saved values from an earlier run are the user's; the current ones may be ours.
        if !isHidden {
            var saved: [String: Any] = [:]
            for key in Self.keys {
                saved[key] = dock.object(forKey: key)  // an absent key stays absent
            }
            store.set(saved, forKey: Self.savedKey)
        }
        dock.set(true, forKey: "autohide")
        dock.set(Self.hiddenDelay, forKey: "autohide-delay")
        restartDock()
    }

    public func restore() {
        guard let saved = store.dictionary(forKey: Self.savedKey) else { return }
        for key in Self.keys {
            if let value = saved[key] {
                dock.set(value, forKey: key)
            } else {
                dock.removeObject(forKey: key)
            }
        }
        store.removeObject(forKey: Self.savedKey)
        restartDock()
    }
}
