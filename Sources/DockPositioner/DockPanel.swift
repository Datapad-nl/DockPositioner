import AppKit
import DockPositionerCore
import Observation
import SwiftUI

@MainActor @Observable
final class DockPanelState {
    var layout: DockLayout
    /// Pointer position in the panel (top-left origin), `nil` when outside.
    var hover: CGPoint?

    init(layout: DockLayout) {
        self.layout = layout
    }
}

/// The Dock on one monitor: a borderless panel that never takes focus.
@MainActor
final class DockPanel {
    private let panel: MenuPanel
    private let state: DockPanelState
    private var autoHide = false
    private var hidden = false
    private var leftAt: TimeInterval?

    init(model: AppModel, layout: DockLayout) {
        state = DockPanelState(layout: layout)
        panel = MenuPanel(contentRect: layout.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Mouse moves over the Dock reach the app's local event monitor.
        panel.acceptsMouseMovedEvents = true
        let view = DockHostingView(rootView: DockView(model: model, state: state))
        view.sizingOptions = []
        panel.contentView = view
        panel.menuAt = { [weak model, state] point in
            let layout = state.layout
            guard let model, let along = layout.hoverAlong(point), let index = layout.item(atAlong: along),
                  index < model.items.count
            else { return nil }
            return model.menu(for: model.items[index])
        }
    }

    func update(layout: DockLayout, autoHide: Bool) {
        state.layout = layout
        self.autoHide = autoHide
        if !autoHide { hidden = false }
        leftAt = nil
        place(animated: false)
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }

    /// Slides an auto-hide Dock in when the pointer reaches the edge, and out once it has left the Dock for a moment.
    func autoHideTick(pointer: CGPoint, now: TimeInterval) {
        guard autoHide else { return }
        let layout = state.layout
        if hidden {
            guard layout.revealsDock(pointer: pointer) else { return }
            hidden = false
            leftAt = nil
            place(animated: true)
        } else if (state.hover != nil ? layout.dockRect : layout.restRect).contains(pointer) {
            leftAt = nil
        } else if let leftAt {
            guard now - leftAt > 0.6 else { return }
            hidden = true
            state.hover = nil
            place(animated: true)
        } else {
            leftAt = now
        }
    }

    /// Lets the mouse through everywhere but the drawn Dock, and feeds the hover from the pointer.
    /// While a mouse button is held the panel keeps taking the mouse or not, so a click is never cut off.
    func pointerMoved(to pointer: CGPoint, buttonsHeld: Bool) {
        let layout = state.layout
        let engaged = state.hover != nil
        if !buttonsHeld {
            let ignores = !layout.acceptsMouse(pointer: pointer, hidden: hidden, engaged: engaged)
            if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
        }
        let frame = layout.frame
        let hover = !panel.ignoresMouseEvents && (engaged ? layout.dockRect : layout.restRect).contains(pointer)
            ? CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y) : nil
        if state.hover != hover { state.hover = hover }
    }

    private func place(animated: Bool) {
        let frame = hidden ? state.layout.hiddenFrame : state.layout.frame
        let alpha: CGFloat = hidden ? 0 : 1
        panel.ignoresMouseEvents = !state.layout.acceptsMouse(pointer: NSEvent.mouseLocation, hidden: hidden, engaged: state.hover != nil)
        guard animated else {
            panel.setFrame(frame, display: true)
            panel.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = alpha
        }
    }
}

/// Shows an item's menu on right-click and Control-click; the menu is built only then.
final class MenuPanel: NSPanel {
    /// The menu for a point in the panel (top-left origin), `nil` when there is no item.
    var menuAt: ((CGPoint) -> NSMenu?)?

    override func sendEvent(_ event: NSEvent) {
        let wantsMenu = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        let location = event.locationInWindow
        if wantsMenu, let view = contentView,
           let menu = menuAt?(CGPoint(x: location.x, y: frame.height - location.y)) {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
        super.sendEvent(event)
    }
}

/// Takes the first click without activating.
final class DockHostingView: NSHostingView<DockView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct DockView: View {
    let model: AppModel
    let state: DockPanelState

    var body: some View {
        let layout = state.layout
        let hoverAlong = state.hover.flatMap(layout.hoverAlong)
        let hovered = hoverAlong.flatMap(layout.item(atAlong:)).flatMap { $0 < model.items.count ? $0 : nil }
        let along = layout.edge == .bottom
        ZStack(alignment: .topLeading) {
            DockBackground(radius: min(18, layout.dockThickness * 0.3))
                .frame(width: along ? layout.dockLength : layout.dockThickness,
                       height: along ? layout.dockThickness : layout.dockLength)
                .position(layout.dockCenter)
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                let size = layout.iconSize * layout.scale(ofItem: index, hoverAlong: hoverAlong)
                let center = layout.center(ofItem: index)
                icon(item, size: size)
                    .overlay(alignment: .topTrailing) {
                        if let badge = model.badges[item.id] { self.badge(badge, iconSize: size) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if model.soundingItems.contains(item.id) { speaker(iconSize: size) }
                    }
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: model.bounces[item.id] ?? 0) { content, hop in
                        content.offset(Self.bounceOffset(hop * layout.bounceHeight, edge: layout.edge))
                    } keyframes: { _ in
                        // Three hops away from the edge, like the Dock's attention bounce, then rest.
                        LinearKeyframe(1, duration: 0.22, timingCurve: .easeOut)
                        LinearKeyframe(0, duration: 0.22, timingCurve: .easeIn)
                        LinearKeyframe(1, duration: 0.22, timingCurve: .easeOut)
                        LinearKeyframe(0, duration: 0.22, timingCurve: .easeIn)
                        LinearKeyframe(1, duration: 0.22, timingCurve: .easeOut)
                        LinearKeyframe(0, duration: 0.22, timingCurve: .easeIn)
                    }
                    .position(layout.point(along: center, across: layout.pad + size / 2))
                    .zIndex(index == hovered ? 1 : 0)
                if model.runningApp(for: item) != nil {
                    Circle()
                        .fill(.primary.opacity(0.8))
                        .frame(width: 4, height: 4)
                        .position(layout.point(along: center, across: layout.pad / 2))
                        .allowsHitTesting(false)
                }
            }
            if let hovered {
                let size = layout.iconSize * layout.scale(ofItem: hovered, hoverAlong: hoverAlong)
                label(model.items[hovered].label, edge: layout.edge, space: layout.labelSpace)
                    .position(layout.point(along: layout.center(ofItem: hovered),
                                           across: layout.pad + size + 6 + layout.labelSpace / 2))
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .frame(width: layout.frame.width, height: layout.frame.height, alignment: .topLeading)
    }

    private func icon(_ item: DockItem, size: CGFloat) -> some View {
        Image(nsImage: model.icon(for: item))
            .resizable()
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onTapGesture { model.open(item) }
    }

    /// A red badge with white text in the icon's top-right corner, like the system Dock's.
    private func badge(_ text: String, iconSize: CGFloat) -> some View {
        let height = (iconSize * 0.36).rounded()
        return Text(text)
            .font(.system(size: height * 0.62, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(Capsule().fill(Color(nsColor: .systemRed)))
            .allowsHitTesting(false)
    }

    /// A white speaker in a dark translucent circle in the icon's bottom-right corner, for an app playing sound.
    private func speaker(iconSize: CGFloat) -> some View {
        let diameter = (iconSize * 0.36).rounded()
        return Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: diameter * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(.black.opacity(0.55)))
            .allowsHitTesting(false)
    }

    /// The offset of a bouncing icon: away from the screen edge.
    nonisolated private static func bounceOffset(_ distance: CGFloat, edge: DockPosition) -> CGSize {
        switch edge {
        case .bottom: return CGSize(width: 0, height: -distance)
        case .left: return CGSize(width: distance, height: 0)
        case .right: return CGSize(width: -distance, height: 0)
        }
    }

    private func label(_ text: String, edge: DockPosition, space: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            .frame(width: edge == .bottom ? 180 : space, height: 28,
                   alignment: edge == .left ? .leading : edge == .right ? .trailing : .center)
    }
}

/// The translucent rounded background, kept "active" although the app never is.
struct DockBackground: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let size = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        view.maskImage = mask
    }
}
