import Foundation

public enum DockPosition: String, Codable, CaseIterable, Sendable {
    case left, bottom, right
}

/// The settings of one monitor's Dock.
public struct DockSettings: Codable, Equatable, Sendable {
    public var position: DockPosition
    public var autoHide: Bool
    public var magnification: Bool
    /// 0.0 (smallest) ... 1.0 (largest)
    public var size: Double

    public init(position: DockPosition, autoHide: Bool, magnification: Bool, size: Double) {
        self.position = position
        self.autoHide = autoHide
        self.magnification = magnification
        self.size = size
    }

    public static let `default` = DockSettings(position: .bottom, autoHide: false, magnification: false, size: 0.5)
}

/// A monitor's profile: the settings, and whether the profile is switched on.
public struct MonitorProfile: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var settings: DockSettings

    public init(isEnabled: Bool, settings: DockSettings) {
        self.isEnabled = isEnabled
        self.settings = settings
    }
}
