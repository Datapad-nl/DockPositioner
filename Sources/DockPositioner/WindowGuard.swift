import AppKit
import ApplicationServices
import DockPositionerCore
import Observation

/// A Dock that windows are kept out of, in AppKit screen coordinates.
struct DockArea: Equatable {
    let screen: CGRect
    let edge: DockPosition
    let thickness: CGFloat
}

/// Keeps other apps' windows out of the Docks with the Accessibility API: a window whose edge is flush with
/// a Dock's screen edge gets that edge moved to the Dock's inner edge (see `frameClearOfDock`).
@MainActor @Observable
final class WindowGuard {
    private(set) var isTrusted = AXIsProcessTrusted()
    /// Docks to keep windows out of: monitors with an enabled profile whose Dock does not auto-hide.
    @ObservationIgnored var docks: [DockArea] = [] {
        didSet { if docks != oldValue { checkAllWindows() } }
    }

    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    /// Windows to check, with the time to check them: shortly after their last move or resize.
    @ObservationIgnored private var pending: [AXUIElement: TimeInterval] = [:]
    @ObservationIgnored private var settleTimer: Timer?
    /// Windows that did not take the frame they were given; trying again could loop.
    @ObservationIgnored private var refused: Set<AXUIElement> = []
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []

    private var isActive: Bool { isEnabled && isTrusted }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncObservers()
                    // A just-launched app may not accept observers yet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.syncObservers() }
                }
            })
        }
    }

    /// `prompt` asks the system to show the Accessibility permission dialog when the app is not trusted.
    func setEnabled(_ enabled: Bool, prompt: Bool) {
        isEnabled = enabled
        isTrusted = enabled && prompt
            ? AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            : AXIsProcessTrusted()
        update()
    }

    private func update() {
        trustTimer?.invalidate()
        trustTimer = nil
        if isEnabled && !isTrusted {
            // Start working as soon as the permission is granted, without a relaunch.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.isTrusted = true
                    self.update()
                }
            }
        }
        syncObservers()
        checkAllWindows()
    }

    // MARK: Observing

    /// Observes every regular app except this one while active, and nothing otherwise.
    private func syncObservers() {
        let own = ProcessInfo.processInfo.processIdentifier
        let wanted = isActive
            ? Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }
                .map(\.processIdentifier))
            : []
        for (pid, observer) in observers where !wanted.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = nil
        }
        for pid in wanted where observers[pid] == nil {
            observers[pid] = makeObserver(pid)
        }
        if !isActive {
            pending = [:]
        }
    }

    private func makeObserver(_ pid: pid_t) -> AXObserver? {
        var made: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let windowGuard = Unmanaged<WindowGuard>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { windowGuard.schedule(element) }
        }
        guard AXObserverCreate(pid, callback, &made) == .success, let observer = made else { return nil }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let added = [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification]
            .filter { AXObserverAddNotification(observer, app, $0 as CFString, refcon) == .success }
        guard !added.isEmpty else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        return observer
    }

    private func schedule(_ window: AXUIElement) {
        guard isActive else { return }
        pending[window] = ProcessInfo.processInfo.systemUptime + 0.3
        guard settleTimer == nil else { return }
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle() }
        }
    }

    /// Checks the windows that are due, unless a mouse button is down (a drag or resize may be going on).
    private func settle() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for (window, due) in pending where due <= now {
            pending[window] = nil
            correct(window)
        }
        if pending.isEmpty {
            settleTimer?.invalidate()
            settleTimer = nil
        }
    }

    private func checkAllWindows() {
        guard isActive else { return }
        for pid in observers.keys {
            let windows: [AXUIElement] = copyAttribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
            windows.forEach(correct)
        }
    }

    // MARK: Correcting

    private func correct(_ window: AXUIElement) {
        guard isActive, !refused.contains(window),
              let primaryHeight = NSScreen.screens.first?.frame.maxY,
              copyAttribute(window, kAXMinimizedAttribute) != true,
              copyAttribute(window, "AXFullScreen") != true,
              let axFrame = frame(of: window)
        else { return }
        let current = flipped(axFrame, primaryHeight: primaryHeight)
        for dock in docks {
            guard let fixed = frameClearOfDock(window: current, screen: dock.screen, edge: dock.edge,
                                               dockThickness: dock.thickness)
            else { continue }
            let target = flipped(fixed, primaryHeight: primaryHeight)
            // Shrink first, then move, so the window never reaches past the far side of the monitor.
            var size = target.size
            var origin = target.origin
            let applied = set(window, kAXSizeAttribute, AXValueCreate(.cgSize, &size))
                && (origin == axFrame.origin || set(window, kAXPositionAttribute, AXValueCreate(.cgPoint, &origin)))
                && frame(of: window).map { matches($0, target) } == true
            if !applied { refused.insert(window) }
            return
        }
    }

    private func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= flushTolerance && abs(a.minY - b.minY) <= flushTolerance
            && abs(a.maxX - b.maxX) <= flushTolerance && abs(a.maxY - b.maxY) <= flushTolerance
    }

    /// The window's frame in Accessibility coordinates.
    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position: AXValue = copyAttribute(window, kAXPositionAttribute),
              let size: AXValue = copyAttribute(window, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private func copyAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func set(_ window: AXUIElement, _ name: String, _ value: AXValue?) -> Bool {
        guard let value else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, name as CFString, &settable) == .success, settable.boolValue
        else { return false }
        return AXUIElementSetAttributeValue(window, name as CFString, value) == .success
    }
}
