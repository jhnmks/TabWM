import AppKit
import SwiftUI
import TabWMCore

enum FrameMetrics {
    /// Approximates the corner radius of standard macOS windows so the border hugs them.
    static let windowCornerRadius: CGFloat = 16
}

/// One panel per group: a glass ring with the tab strip on top and a thin border on the
/// other three sides. It is ordered directly *above* the group's active window, so the
/// strip can never be hidden by its own window (for example when maximized), while other
/// apps' windows still stack over the whole group. The middle is a transparent hole; the
/// controller makes the panel click-through while the pointer is over it.
@MainActor
final class GroupFramePanel: NSPanel {
    weak var controller: AppController?
    let groupID: UUID
    private(set) var anchorWindowID: UInt32?
    private var lastSize: NSSize = .zero

    init(controller: AppController, groupID: UUID) {
        self.controller = controller; self.groupID = groupID
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .normal; isOpaque = false; backgroundColor = .clear; hasShadow = false; isReleasedWhenClosed = false
        // Transient: macOS leaves it out of Mission Control, App Exposé, and window cycling.
        // A managed panel shows up there as an empty frame and can catch overview clicks.
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]; hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: GroupFrameView(controller: controller, groupID: groupID))
        host.sizingOptions = []
        contentView = host
    }
    override var canBecomeKey: Bool { false }
    /// Keeps the frame directly above its window after clicks on it.
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if [.leftMouseDown, .rightMouseDown, .leftMouseUp].contains(event.type) { restack() }
    }
    /// Puts the frame directly above its window.
    func restack() {
        guard let anchorWindowID, isVisible else { return }
        order(.above, relativeTo: Int(anchorWindowID))
    }

    var thickness: CGFloat { CGFloat((controller?.settings ?? AppSettings()).frameThickness) }
    var barHeight: CGFloat { CGFloat((controller?.settings ?? AppSettings()).tabBarHeight) }
    /// Screen-space rectangle of the tab strip and the shell above it; the drop target for dragged tabs.
    var barRect: NSRect { NSRect(x: frame.minX, y: frame.maxY - barHeight - thickness, width: frame.width, height: barHeight + thickness) }
    /// Screen-space rectangle of the window inside the ring.
    var holeRect: NSRect {
        NSRect(x: frame.minX + thickness, y: frame.minY + thickness,
               width: max(0, frame.width - 2 * thickness), height: max(0, frame.height - 2 * thickness - barHeight))
    }

    func update(_ group: TabWMCore.WindowGroup) {
        guard let controller else { return }
        let visible = group.members.compactMap(controller.window).filter { $0.isOnScreen && !$0.isMinimized && !$0.isFullscreen }
        guard let target = visible.first(where: { $0.id == group.activeWindowID }) ?? visible.first else { orderOut(nil); return }
        // The window server's frame is current even mid-drag; the census may be 350 ms old.
        place(around: WindowSystem.serverFrame(target.id) ?? target.frame, windowID: target.id)
        restack()
    }


    /// `windowFrame` uses Accessibility coordinates (top-left origin on the primary display).
    func place(around windowFrame: CGRect, windowID: UInt32) {
        guard let controller else { return }
        let t = thickness, bar = barHeight
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: windowFrame.minX - t, y: primaryHeight - windowFrame.maxY - t,
                          width: windowFrame.width + 2 * t, height: windowFrame.height + 2 * t + bar).integral
        if frame != rect {
            if rect.size == lastSize {
                // A pure move never relayouts the content.
                setFrameOrigin(rect.origin)
            } else {
                // Disable implicit animations so the glass doesn't trail the window edge.
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                NSAnimationContext.current.allowsImplicitAnimation = false
                setFrame(rect, display: true, animate: false)
                NSAnimationContext.endGrouping()
                lastSize = rect.size
            }
        }
        let alpha = max(0.3, min(1, controller.settings.tabBarOpacity))
        if alphaValue != alpha { alphaValue = alpha }
        if anchorWindowID != windowID || !isVisible {
            anchorWindowID = windowID
            if !isVisible { orderFront(nil) }
            restack()
        }
    }
}

struct GroupFrameView: View {
    @ObservedObject var controller: AppController
    let groupID: UUID
    var body: some View {
        if let group = controller.groups.first(where: { $0.id == groupID }) {
            let t = CGFloat(controller.settings.frameThickness)
            let bar = CGFloat(controller.settings.tabBarHeight)
            let shape = RoundedRectangle(cornerRadius: FrameMetrics.windowCornerRadius + t, style: .continuous)
            ZStack(alignment: .top) {
                if controller.settings.frameStyle == "catppuccin" {
                    // One solid accent shell around the tab strip and the window.
                    Catppuccin.accent(controller.settings.frameColor)
                        .mask { FrameRing(thickness: t, barHeight: bar).fill(style: FillStyle(eoFill: true)) }
                } else {
                    Color.clear
                        .liquidGlass(in: shape)
                        .mask { FrameRing(thickness: t, barHeight: bar).fill(style: FillStyle(eoFill: true)) }
                }
                TabStripView(controller: controller, group: group)
                    .frame(height: bar)
                    .padding([.horizontal, .top], t)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The outer shell minus the window-shaped hole, filled even-odd. The shell is equally thick
/// on every side: above the tab strip, and left, right, and below the window.
struct FrameRing: Shape {
    let thickness: CGFloat
    let barHeight: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: FrameMetrics.windowCornerRadius + thickness, style: .continuous)
        let hole = CGRect(x: rect.minX + thickness, y: rect.minY + thickness + barHeight,
                          width: rect.width - 2 * thickness, height: rect.height - barHeight - 2 * thickness)
        if hole.width > 0, hole.height > 0 {
            path.addPath(Path(roundedRect: hole, cornerRadius: FrameMetrics.windowCornerRadius, style: .continuous))
        }
        return path
    }
}

/// Shown over the target window while a modifier-drag is about to create or join a group.
struct GroupDropPreview: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FrameMetrics.windowCornerRadius, style: .continuous)
        shape.fill(Color.accentColor.opacity(0.12))
            .liquidGlass(in: shape, tint: Color.accentColor.opacity(0.35), clear: true)
            .overlay { shape.strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2) }
            .overlay {
                Label("Release to group", systemImage: "rectangle.stack.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .liquidGlass(in: Capsule())
            }
            .padding(2)
    }
}

// MARK: - Tab strip

struct TabStripView: View {
    @ObservedObject var controller: AppController
    let group: TabWMCore.WindowGroup
    var body: some View {
        LiquidGlassGroup(spacing: 4) {
            HStack(spacing: 3) {
                if group.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary).padding(.leading, 6).help("Group is locked")
                }
                if let name = group.name, !name.isEmpty {
                    Text(name).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .lineLimit(1).frame(maxWidth: 110, alignment: .leading).padding(.horizontal, 6)
                }
                ForEach(group.members, id: \.self) { id in
                    TabItemView(controller: controller, group: group, id: id)
                }
                Spacer(minLength: 8)
                if NSScreen.screens.count > 1 {
                    Menu {
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                            Button(screen.localizedName) { controller.moveGroup(group, to: screen) }
                        }
                    } label: { Image(systemName: "macwindow.on.rectangle").font(.system(size: 11, weight: .medium)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(.secondary).help("Move to Display")
                }
                PaletteDot(controller: controller)
                if controller.settings.searchEnabled {
                    BarIconButton(symbol: "magnifyingglass", help: "Search tabs") { controller.showSearch() }
                }
                BarIconButton(symbol: "plus", help: "Add window") { controller.showWindowPicker(target: group.activeWindowID) }
                    .disabled(group.isLocked)
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        }
        // Empty strip space catches right-clicks; groups don't move, so there is no drag.
        .background { Color.clear.contentShape(Rectangle()) }
        .contextMenu { GroupMenuItems(controller: controller, group: group) }
    }
}

struct TabItemView: View {
    @ObservedObject var controller: AppController
    let group: TabWMCore.WindowGroup
    let id: UInt32
    @State private var hovering = false
    @State private var dragOffset: CGSize = .zero
    var active: Bool { group.activeWindowID == id }
    var dragging: Bool { dragOffset != .zero }

    static let activeFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.78)
    })

    var catppuccin: Bool { controller.settings.frameStyle == "catppuccin" }
    var selectedFill: Color { catppuccin ? Catppuccin.base : Self.activeFill }
    /// Color mode: every tab is a card on the accent shell; the others are faded.
    var fill: Color {
        if active || dragging { return selectedFill }
        if catppuccin { return Catppuccin.base.opacity(hovering ? 0.75 : 0.5) }
        return hovering ? Color.primary.opacity(0.07) : Color.clear
    }
    var shadowOpacity: Double { active || dragging ? (catppuccin ? 0.3 : 0.14) : 0 }

    var body: some View {
        let info = controller.window(id)
        let title = controller.tabTitle(id)
        HStack(spacing: 6) {
            if let icon = controller.system.appIcon(id) { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 15, height: 15) }
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(catppuccin ? (active ? Catppuccin.text : Catppuccin.subtext) : (active ? Color.primary : Color.secondary))
                .lineLimit(1).truncationMode(.tail)
            if group.suspended.contains(id) { Image(systemName: "pause.circle").font(.system(size: 10)).foregroundStyle(.tertiary) }
            if controller.settings.showBadges, let info { DockBadgeView(badges: controller.badges, bundleID: info.bundleID) }
            Spacer(minLength: 0)
        }
        .opacity(catppuccin && !active && !dragging && !hovering ? 0.7 : 1)
        .padding(.horizontal, 10)
        .frame(minWidth: 48, maxWidth: 200, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
                .shadow(color: .black.opacity(shadowOpacity), radius: dragging ? 8 : (catppuccin ? 3 : 1.5), y: dragging ? 3 : (catppuccin ? 1.5 : 0.5))
        }
        .overlay(alignment: .trailing) {
            if hovering && !dragging {
                Button { controller.closeTab(id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Self.activeFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.trailing, 5).help("Close Window")
                .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { controller.activate(id) }
        .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { dragOffset = $0.translation }
            .onEnded { _ in dragOffset = .zero; controller.finishTabDrag(id: id, at: NSEvent.mouseLocation) })
        .offset(dragOffset)
        .scaleEffect(dragging ? 1.03 : 1)
        .zIndex(dragging ? 1 : 0)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.tabFrames[id] = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
        .animation(.snappy(duration: 0.2), value: active)
        .animation(.interactiveSpring(), value: dragOffset)
        .help(title)
        .contextMenu {
            Button("Activate") { controller.activate(id) }
            Button("Detach Tab") { controller.detachTab(id) }.disabled(group.isLocked)
            Menu("Move to Group") {
                ForEach(controller.groups.filter { $0.id != group.id }) { other in
                    Button(other.name ?? "Group \(other.id.uuidString.prefix(4))") {
                        controller.engine.moveMember(id, to: other.activeWindowID, atIndex: other.members.count)
                        controller.layoutGroup(containing: id); controller.activate(id)
                    }.disabled(group.isLocked || other.isLocked)
                }
            }
            Divider(); Button("Close Window") { controller.closeTab(id) }
            Divider(); GroupMenuItems(controller: controller, group: group)
        }
    }
}

struct GroupMenuItems: View {
    @ObservedObject var controller: AppController
    let group: TabWMCore.WindowGroup
    var body: some View {
        Button("Rename Group…") { controller.rename(group) }
        Button(group.isLocked ? "Unlock Group" : "Lock Group") { controller.engine.setLocked(group.id, locked: !group.isLocked) }

        Menu("Move to Display") { ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in Button(screen.localizedName) { controller.moveGroup(group, to: screen) } } }
        Button("Add Window…") { controller.showWindowPicker(target: group.activeWindowID) }.disabled(group.isLocked)
        Divider()
        Button("Ungroup") { controller.engine.dissolve(group.id) }.disabled(group.isLocked)
        Button("Close All Windows…") { controller.closeGroup(group) }
    }
}

struct BarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 24, height: 22)
                .background(hovering ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}

struct DockBadgeView: View {
    @ObservedObject var badges: DockBadges
    let bundleID: String
    var body: some View {
        if let value = badges.counts[bundleID] {
            Text(value).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Color.red, in: Capsule()).help(value)
        }
    }
}
