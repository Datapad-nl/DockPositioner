import AppKit
import ApplicationServices
import DockPositionerCore

extension AppModel {
    /// The right-click menu of a Dock item, built when it opens: window titles need Accessibility calls.
    func menu(for item: DockItem) -> NSMenu {
        let app = runningApp(for: item)
        let trusted = app != nil && AXIsProcessTrusted()
        let windows = trusted ? app.map { axWindows(of: $0.processIdentifier) } ?? [] : []
        let context = DockMenuContext(
            isRunning: app != nil,
            isHidden: app?.isHidden ?? false,
            isPinned: isPinned(item),
            isTrusted: trusted,
            optionHeld: NSEvent.modifierFlags.contains(.option),
            windows: windows.map { window in
                DockWindowInfo(title: axAttribute(window, kAXTitleAttribute) ?? "",
                               isMinimized: axAttribute(window, kAXMinimizedAttribute) == true)
            }
        )
        return makeMenu(dockMenu(for: item, context: context)) { [weak self] entry in
            switch entry {
            case .window(_, let index, _):
                guard let app else { return }
                self?.raise(windows[index], of: app)
            case .action(_, let action, _):
                self?.perform(action, on: item, app: app)
            case .submenu, .separator:
                break
            }
        }
    }

    private func makeMenu(_ entries: [DockMenuEntry], choose: @escaping (DockMenuEntry) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = makeMenu(children, choose: choose)
                menu.addItem(item)
            case .window(let title, _, let isMinimized):
                let item = ActionMenuItem(title: title) { choose(entry) }
                if isMinimized {
                    // The Dock marks minimised windows with a diamond.
                    item.onStateImage = NSImage(systemSymbolName: "diamond.fill", accessibilityDescription: "Minimised")?
                        .withSymbolConfiguration(.init(pointSize: 7, weight: .regular))
                    item.state = .on
                }
                menu.addItem(item)
            case .action(let title, _, let isChecked):
                let item = ActionMenuItem(title: title) { choose(entry) }
                item.state = isChecked ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    private func perform(_ action: DockMenuAction, on item: DockItem, app: NSRunningApplication?) {
        switch action {
        case .open: open(item)
        case .pin: setPinned(true, item: item)
        case .unpin: setPinned(false, item: item)
        case .showInFinder: NSWorkspace.shared.activateFileViewerSelecting([item.url])
        case .hide: app?.hide()
        case .unhide: app?.unhide()
        case .quit: app?.terminate()
        case .forceQuit: app?.forceTerminate()
        case .emptyTrash: emptyTrash()
        }
    }

    /// Asks Finder, which shows its own confirmation. Needs the Automation permission for Finder.
    private func emptyTrash() {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
            if let error { NSLog("DockPositioner: could not empty the Trash: \(error)") }
        }
    }

    // MARK: Windows

    private func axWindows(of pid: pid_t) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)  // a hanging app must not hold up the menu for long
        return axAttribute(element, kAXWindowsAttribute) ?? []
    }

    private func raise(_ window: AXUIElement, of app: NSRunningApplication) {
        if axAttribute(window, kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate()
    }

    private func axAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func run() {
        handler()
    }
}
