import Foundation

/// Stores profiles in UserDefaults as JSON, keyed by display UUID.
public struct ProfileStore {
    private let defaults: UserDefaults
    private let key = "profiles"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [String: MonitorProfile] {
        guard let data = defaults.data(forKey: key),
              let profiles = try? JSONDecoder().decode([String: MonitorProfile].self, from: data)
        else { return [:] }
        return profiles
    }

    public func save(_ profiles: [String: MonitorProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: key)
    }
}
