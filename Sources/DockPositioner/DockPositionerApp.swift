import DockPositionerCore
import SwiftUI

@main
struct DockPositionerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("DockPositioner", systemImage: "dock.rectangle") {
            MenuView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.monitors) { monitor in
                MonitorSection(model: model, monitor: monitor)
                Divider()
            }
            Toggle("Keep windows out of the Dock", isOn: $model.keepWindowsOutOfDock)
            if model.keepWindowsOutOfDock && !model.windowGuard.isTrusted {
                HStack {
                    Text("Needs Accessibility permission.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            Toggle("Start at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if let error = model.launchAtLoginError {
                Text(error).foregroundStyle(.secondary).lineLimit(1)
            }
            Toggle("Bounce icons on new badges", isOn: $model.bounceOnBadges)
            Toggle("Show speaker on apps playing sound", isOn: $model.showSoundMarks)
            HStack {
                Toggle("Hide system Dock", isOn: $model.hideSystemDock)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
    }
}

struct MonitorSection: View {
    let model: AppModel
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(monitor.name).font(.headline)
            Toggle("Use a profile for this monitor", isOn: Binding(
                get: { model.profiles[monitor.id]?.isEnabled ?? false },
                set: { $0 ? model.enableProfile(for: monitor.id) : model.disableProfile(for: monitor.id) }
            ))
            if model.profiles[monitor.id]?.isEnabled == true {
                Picker("Position", selection: setting(\.position)) {
                    ForEach(DockPosition.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Auto-hide", isOn: setting(\.autoHide))
                Toggle("Magnification", isOn: setting(\.magnification))
                HStack {
                    Text("Size")
                    Slider(value: setting(\.size), in: 0...1)
                }
            }
        }
    }

    private func setting<T>(_ keyPath: WritableKeyPath<DockSettings, T>) -> Binding<T> {
        Binding(
            get: { (model.profiles[monitor.id]?.settings ?? .default)[keyPath: keyPath] },
            set: { value in
                guard var profile = model.profiles[monitor.id] else { return }
                profile.settings[keyPath: keyPath] = value
                model.setProfile(profile, for: monitor.id)
            }
        )
    }
}
