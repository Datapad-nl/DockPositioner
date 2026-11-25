import AppKit
import DockPositionerCore
import Observation
import ServiceManagement

struct Monitor: Identifiable {
    let id: String  // display UUID
    let name: String
    let frame: NSRect
    let topInset: CGFloat  // menu bar height
}

@MainActor @Observable
final class AppModel {
    private(set) var monitors: [Monitor] = []
    private(set) var profiles: [String: MonitorProfile]
    private(set) var items: [DockItem] = []
    private(set) var trashIsFull = false
    private(set) var runningApps: [NSRunningApplication] = []
    /// The system Dock's badges by item id, read while the app has the Accessibility permission.
    private(set) var badges: [String: String] = [:]
    /// How often each item (by id) has bounced; a change starts the bounce animation.
    private(set) var bounces: [String: Int] = [:]
    /// The ids of the items that show the speaker mark: apps with an audio output running.
    private(set) var soundingItems: Set<String> = []
    var hideSystemDock: Bool {
        didSet {
            UserDefaults.standard.set(hideSystemDock, forKey: Self.hideSystemDockKey)
            hideSystemDock ? systemDock.hide() : systemDock.restore()
        }
    }

    var keepWindowsOutOfDock: Bool {
        didSet {
            UserDefaults.standard.set(keepWindowsOutOfDock, forKey: Self.keepWindowsOutOfDockKey)
            windowGuard.setEnabled(keepWindowsOutOfDock, prompt: keepWindowsOutOfDock)
        }
    }
    var bounceOnBadges: Bool {
        didSet { UserDefaults.standard.set(bounceOnBadges, forKey: Self.bounceOnBadgesKey) }
    }
    var showSoundMarks: Bool {
        didSet {
            UserDefaults.standard.set(showSoundMarks, forKey: Self.showSoundMarksKey)
            if !showSoundMarks {
                soundMarks = SoundMarks()
                if !soundingItems.isEmpty { soundingItems = [] }
            }
        }
    }

    let windowGuard = WindowGuard()
    // Not stored by us: the system is the source of truth, so this is re-read after every change.
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchAtLoginError: String?

    private static let hideSystemDockKey = "hideSystemDock"
    private static let keepWindowsOutOfDockKey = "keepWindowsOutOfDock"
    private static let bounceOnBadgesKey = "bounceOnBadges"
    private static let showSoundMarksKey = "showSoundMarks"
    @ObservationIgnored private let store = ProfileStore()
    @ObservationIgnored private let dockDefaults = UserDefaults(suiteName: "com.apple.dock")!
    @ObservationIgnored private let systemDock: SystemDockHider
    @ObservationIgnored private var panels: [String: DockPanel] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var mouseMonitors: [Any] = []
    @ObservationIgnored private var openMenus = 0
    @ObservationIgnored private var termSource: (any DispatchSourceSignal)?
    /// The system Dock process that `badges` were read from; `nil` before the first read with the permission.
    @ObservationIgnored private var badgesDockPID: pid_t?
    @ObservationIgnored private var readingBadges = false
    @ObservationIgnored private var soundMarks = SoundMarks()
    @ObservationIgnored private var readingSound = false
    // Without a visible window the app is eligible for App Nap, which would throttle the auto-hide timer.
    @ObservationIgnored private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Show auto-hidden Docks at the pointer"
    )

    init() {
        profiles = store.load()
        hideSystemDock = UserDefaults.standard.bool(forKey: Self.hideSystemDockKey)
        keepWindowsOutOfDock = UserDefaults.standard.bool(forKey: Self.keepWindowsOutOfDockKey)
        // A missing key reads as on.
        bounceOnBadges = UserDefaults.standard.object(forKey: Self.bounceOnBadgesKey) as? Bool ?? true
        showSoundMarks = UserDefaults.standard.object(forKey: Self.showSoundMarksKey) as? Bool ?? true
        systemDock = SystemDockHider(dock: dockDefaults, store: .standard, restartDock: Self.restartDock)
        // Panels are made once the app has finished launching.
        Task { @MainActor in start() }
    }

    /// Makes the system Dock load its preferences again.
    nonisolated private static func restartDock() {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        do {
            try Process.run(URL(fileURLWithPath: "/usr/bin/killall"), arguments: ["Dock"]).waitUntilExit()
        } catch {
            NSLog("DockPositioner: could not restart the Dock: \(error)")
        }
    }

    private func start() {
        hideSystemDock ? systemDock.hide() : systemDock.restore()
        windowGuard.setEnabled(keepWindowsOutOfDock, prompt: false)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMonitors() }
        })
        observers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDock.restore() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshItems() }
            })
        }
        // `pkill` and logout: quit normally so the system Dock is restored.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApplication.shared.terminate(nil) } }
        source.resume()
        termSource = source

        // A context menu from the Dock keeps the panel as it is until the menu closes.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openMenus += 1 }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openMenus = max(0, self.openMenus - 1)
                self.pointerMoved()
            }
        })
        // Switch the panels' mouse handling as the pointer moves, before a click can land. Mouse-move monitors
        // need no Accessibility permission. Global sees moves over other apps, local those over the Docks.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            mouseMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            mouseMonitors.append(monitor)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pointerMoved()
                self.ticks += 1
                if self.ticks % 20 == 0 { self.refreshSound() }  // every second
                if self.ticks % 40 == 0 {  // every 2 s
                    self.refreshTrash()
                    self.refreshBadges()
                }
                let pointer = NSEvent.mouseLocation
                let now = ProcessInfo.processInfo.systemUptime
                for panel in self.panels.values { panel.autoHideTick(pointer: pointer, now: now) }
            }
        }

        refreshMonitors()
        refreshItems()
        refreshTrash()
        refreshBadges()
    }

    /// Reads the system Dock's badges off the main thread, so a busy Dock cannot hold up the Docks, and bounces
    /// the icons whose badge appeared or went up. The first badges read from a Dock process never bounce.
    private func refreshBadges() {
        guard AXIsProcessTrusted() else {
            badgesDockPID = nil
            if !badges.isEmpty { badges = [:] }
            return
        }
        guard !readingBadges,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?
                .processIdentifier
        else { return }
        readingBadges = true
        Task {
            let entries = await Task.detached { readSystemDockBadges(dockPID: pid) }.value
            readingBadges = false
            guard let entries, AXIsProcessTrusted() else { return }
            let new = DockPositionerCore.badges(of: entries, for: items)
            let frontmost = NSWorkspace.shared.frontmostApplication.flatMap(item(for:))
                .flatMap { app in items.first(where: { $0.isSameApp(as: app) }) }?.id
            let bounce = itemsToBounce(from: badgesDockPID == pid ? badges : nil, to: new, frontmost: frontmost)
            badgesDockPID = pid
            if new != badges { badges = new }
            // Tracking above carries on when bouncing is off, so only later changes bounce after it is switched on.
            guard bounceOnBadges else { return }
            for id in bounce { bounces[id, default: 0] += 1 }
        }
    }

    /// Reads which processes have an audio output running off the main thread, and updates the speaker marks
    /// only when the set of marked items changes. Does nothing while the marks are switched off.
    private func refreshSound() {
        guard #available(macOS 14.2, *), showSoundMarks, !readingSound else { return }
        readingSound = true
        Task {
            let processes = await Task.detached { readSoundingAudioProcesses() }.value
            readingSound = false
            guard showSoundMarks else { return }
            if soundMarks.update(sounding: itemsPlayingSound(processes, items: items)) {
                soundingItems = soundMarks.marked
            }
        }
    }

    /// Polls the link count of the Trash folders with `lstat`: listing them needs Full Disk Access, `stat` does not.
    /// Observable state changes only when the result does, so the Dock redraws only then.
    private func refreshTrash() {
        let full = Self.trashFolders().contains(where: Self.folderHasItems)
        if full != trashIsFull { trashIsFull = full }
    }

    private static func trashFolders() -> [String] {
        var folders = [NSHomeDirectory() + "/.Trash"]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" {
            folders.append(volume.path + "/.Trashes/\(getuid())")
        }
        return folders
    }

    private static func folderHasItems(_ path: String) -> Bool {
        var info = stat()
        let linkCount = lstat(path, &info) == 0 ? Int(info.st_nlink) : nil
        // stat on a path inside the Trash is allowed without Full Disk Access (ENOENT when absent), so a
        // stray .DS_Store can be subtracted exactly.
        var inner = stat()
        return trashHasItems(linkCount: linkCount, hasDSStore: lstat(path + "/.DS_Store", &inner) == 0)
    }

    private func pointerMoved() {
        guard openMenus == 0 else { return }
        let pointer = NSEvent.mouseLocation
        let held = NSEvent.pressedMouseButtons != 0
        for panel in panels.values { panel.pointerMoved(to: pointer, buttonsHeld: held) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Profiles

    func setProfile(_ profile: MonitorProfile, for id: String) {
        profiles[id] = profile
        store.save(profiles)
        updatePanels()
    }

    func enableProfile(for id: String) {
        var profile = profiles[id] ?? MonitorProfile(isEnabled: true, settings: .default)
        profile.isEnabled = true
        setProfile(profile, for: id)
    }

    func disableProfile(for id: String) {
        guard var profile = profiles[id] else { return }
        profile.isEnabled = false
        setProfile(profile, for: id)
    }

    // MARK: Items

    func runningApp(for item: DockItem) -> NSRunningApplication? {
        guard item.kind == .app else { return nil }
        return runningApps.first { app in self.item(for: app).map(item.isSameApp) ?? false }
    }

    func icon(for item: DockItem) -> NSImage {
        // Not cached: the Trash icon changes with trashIsFull, which also makes the views that read it redraw.
        if item.kind == .trash {
            return NSImage(named: trashIsFull ? NSImage.trashFullName : NSImage.trashEmptyName)
                ?? NSWorkspace.shared.icon(forFile: item.url.path)
        }
        if let icon = icons[item.id] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icons[item.id] = icon
        return icon
    }

    func open(_ item: DockItem) {
        guard item.kind == .app else {
            NSWorkspace.shared.open(item.url)  // folders and the Trash open in Finder
            return
        }
        // Launches the app, or activates it when it runs.
        NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("DockPositioner: could not open \(item.url.path): \(error)") }
        }
    }

    func isPinned(_ item: DockItem) -> Bool {
        pinnedApps().contains(where: item.isSameApp)
    }

    private func pinnedApps() -> [DockItem] {
        dockItems(fromPreference: dockDefaults.array(forKey: "persistent-apps"), kind: .app)
    }

    /// Adds the app to the system Dock's list or removes it, so both Docks show the same apps.
    func setPinned(_ pinned: Bool, item: DockItem) {
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString
        CFPreferencesAppSynchronize(domain)
        let entries = CFPreferencesCopyAppValue(key, domain) as? [Any] ?? []
        let changed = pinned
            ? addingDockEntry(to: entries, appURL: item.url, label: item.label, bundleID: item.bundleID)
            // The pinned entry may be found by bundle identifier at another location than the running app.
            : removingDockEntry(from: entries, appURL: pinnedApps().first(where: item.isSameApp)?.url ?? item.url)
        guard changed.count != entries.count else { return }
        CFPreferencesSetAppValue(key, changed as NSArray, domain)
        Self.restartDock()
        refreshItems()
    }

    private func item(for app: NSRunningApplication) -> DockItem? {
        guard let url = app.bundleURL else { return nil }
        return DockItem(kind: .app, url: url, label: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                        bundleID: app.bundleIdentifier)
    }

    private func refreshItems() {
        runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        items = mergedDockItems(
            finder: DockItem(kind: .app, url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                             label: "Finder", bundleID: "com.apple.finder"),
            pinned: dockItems(fromPreference: dockDefaults.array(forKey: "persistent-apps"), kind: .app),
            running: runningApps.compactMap(item(for:)),
            others: dockItems(fromPreference: dockDefaults.array(forKey: "persistent-others"), kind: .folder),
            trash: DockItem(kind: .trash, url: trashURL, label: "Trash")
        )
        updatePanels()
    }

    // MARK: Monitors and panels

    private func refreshMonitors() {
        monitors = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            else { return nil }
            return Monitor(id: CFUUIDCreateString(nil, uuid) as String, name: screen.localizedName,
                           frame: screen.frame, topInset: screen.frame.maxY - screen.visibleFrame.maxY)
        }
        updatePanels()
    }

    private func updatePanels() {
        var next: [String: DockPanel] = [:]
        var docks: [DockArea] = []
        for monitor in monitors {
            guard let profile = profiles[monitor.id], profile.isEnabled else { continue }
            let layout = DockLayout(settings: profile.settings, itemCount: items.count,
                                    screen: monitor.frame, topInset: monitor.topInset)
            let panel = panels[monitor.id] ?? DockPanel(model: self, layout: layout)
            panel.update(layout: layout, autoHide: profile.settings.autoHide)
            next[monitor.id] = panel
            if !profile.settings.autoHide {
                // The background touches the screen edge, so its thickness is all the room the Dock takes.
                docks.append(DockArea(screen: monitor.frame, edge: layout.edge, thickness: layout.dockThickness))
            }
        }
        for (id, panel) in panels where next[id] == nil {
            panel.close()
        }
        panels = next
        windowGuard.docks = docks
    }
}
