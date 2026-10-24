import AppKit
import SwiftUI
import Carbon
import ServiceManagement
import UniformTypeIdentifiers
import TabWMCore
import os

@main
struct TabWMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let index=CommandLine.arguments.firstIndex(of:"--smoke-output"), CommandLine.arguments.indices.contains(index+1) {
            runUISmoke(output:URL(fileURLWithPath:CommandLine.arguments[index+1]));return
        }
        controller = AppController()
        controller.start()
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
}

let membershipLog = Logger(subsystem: "dev.tabwm.TabWM", category: "membership")

@MainActor
final class AppController: NSObject, ObservableObject, NSMenuDelegate {
    let system = WindowSystem()
    let engine = GroupEngine()
    let nativeTabs = NativeTabTracker()
    var pendingNativeMembers: Set<UInt32> = []
    var repointingNativeTabs = false
    let badges = DockBadges()
    @Published var windows: [WindowInfo] = []
    @Published var groups: [TabWMCore.WindowGroup] = []
    @Published var settings = AppSettings()
    @Published var status = ""
    @Published var paused = false
    var statusItem: NSStatusItem!
    var overlays: [UUID: GroupFramePanel] = [:]
    /// Tab rectangles in their panel's top-left coordinates; not published to avoid layout loops.
    var tabFrames: [UInt32: CGRect] = [:]
    var hoverMonitors: [Any] = []
    /// Window-server events for grouped windows; replaces most polling when available.
    let windowEvents = WindowEvents()
    /// Windows we just repositioned asynchronously; censuses ignore them until the write lands.
    var recentWrites: [UInt32: TimeInterval] = [:]
    /// Where each member settled after TabWM placed it: the group frame, or the closest size
    /// the app accepts (minimum/maximum sizes). Any other frame means it left the group.
    var restingFrames: [UInt32: CGRect] = [:]
    /// Until then, groups are re-fitted to their screens instead of members leaving
    /// (macOS shuffles windows after display changes and wake).
    var relayoutUntil: TimeInterval = 0
    var settingsWindow: NSWindow?
    var searchWindow: NSWindow?
    var windowPicker: NSWindow?
    lazy var shortcuts = ShortcutMonitor { [weak self] action in self?.perform(action) }
    /// Last login-item problem, shown next to the toggle in General settings.
    @Published var loginItemMessage: String?
    var dragMonitor: Any?
    var dragSource: UInt32?
    var dragTarget: UInt32?
    var dragOrder: [UInt32] = []
    var candidateSince: Date?
    var dragStart: NSPoint?
    var dragOriginalFrame: CGRect?
    var preview: NSPanel?
    var startupRestore: [TabWMCore.WindowGroup]?
    var didRestore = false
    var spaceObserver: NSObjectProtocol?
    var workspaceObservers: [NSObjectProtocol] = []
    var isSpaceTransitioning = false
    var spaceGeneration = 0
    /// When the last Space switch settled; off-Space detaching waits a moment after it.
    var spaceSettledAt: TimeInterval = 0
    var offSpaceSince: [UInt32: TimeInterval] = [:]
    var displayRecoveryUntil = 0.0
    var startupPIDs: [UInt32: Int32] = [:]
    var appliedLoginPreference: Bool?
    var appliedMetrics: CGSize?
    /// Each group's desktop label ("Desktop 2"), refreshed every minute, after Space switches,
    /// and when groups change. Shown in the menu bar menu and in tab search.
    @Published var groupDesktops: [UUID: String] = [:]
    var desktopTimer: Timer?
    var recentMinimizeChanges: [UInt32:TimeInterval] = [:]
    /// Session state (open groups). Stays in Application Support: it isn't configuration.
    let storage: URL
    /// Where settings.toml lives: $XDG_CONFIG_HOME/TabWM, or ~/.config/TabWM.
    let configDirectory: URL

    override convenience init() { self.init(dataDirectory: nil) }
    init(dataDirectory: URL?) {
        storage = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TabWM", isDirectory: true)
        configDirectory = dataDirectory ?? Self.xdgConfigDirectory
        super.init()
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        // settings.toml is the one place settings live, in the same format as an export.
        if let saved = try? SettingsFile.load(from: settingsURL) { settings = saved }
        else if let old = Self.legacySettings(storage: storage, config: configDirectory) {
            // Earlier builds kept JSON (in Application Support, later ~/.config); carry it over once.
            settings = old
        }
        if let data = try? Data(contentsOf: storage.appendingPathComponent("session.json")),
           let saved = try? JSONDecoder().decode(SavedSession.self, from: data),
           abs(saved.bootTime - Self.bootTime) < 5, let pids = saved.pids { startupRestore = saved.groups; startupPIDs = pids }
        engine.onChange = { [weak self] in self?.engineChanged() }
        system.onRefresh = { [weak self] in self?.refresh($0) }
    }

    static var bootTime: TimeInterval { Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime }
    struct SavedSession: Codable { var bootTime: TimeInterval; var groups: [TabWMCore.WindowGroup]; var pids: [UInt32:Int32]? }
    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "TabWM")
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        _ = shortcuts
        windowEvents.onEvent = { [weak self] event, id in self?.handleWindowEvent(event, id) }
        windowEvents.start()
        // With live events the census is a safety net; without them it drives everything.
        system.pollInterval = windowEvents.active ? 1.0 : 0.35
        applySettings()
        watchSettingsFile()
        badges.start()
        desktopTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGroupDesktops() }
        }
        system.start()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSpaceTransitioning = true
                self.spaceGeneration &+= 1
                let generation = self.spaceGeneration
                // Show the arriving Space's strips right away from the window server's live
                // state, instead of after the settle wait below.
                self.showStripsForCurrentSpace()
                try? await Task.sleep(for: .milliseconds(700))
                // A second switch during the wait restarts the clock.
                guard generation == self.spaceGeneration else { return }
                self.isSpaceTransitioning = false
                // Membership decisions wait for a census taken on the settled Space.
                self.spaceSettledAt = ProcessInfo.processInfo.systemUptime
                self.system.refresh()
                self.updateOverlays()
                self.updateGroupDesktops()
            }
        }
        workspaceObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object:nil, queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.displayRecoveryUntil = now + 15
                self.relayoutUntil = now + 5
                self.relayoutAll()
            }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    guard let self else { return }
                    if notification.name == NSWorkspace.willSleepNotification { self.system.stop(); self.overlays.values.forEach { $0.orderOut(nil) }; self.saveSession() }
                    else { self.relayoutUntil = ProcessInfo.processInfo.systemUptime + 5; self.system.start() }
                }
            })
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackDrag(event) }
        }

        // Window-manager shortcuts (Vorssaint's ⌃⌥, Rectangle, …) count as the user. Their
        // keys may never reach us, but their modifiers do. Globe alone is TabWM's leader.
        hoverMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                // Plain typing doesn't count: apps that resize themselves while you type are put back.
                guard !event.modifierFlags.intersection([.control, .option, .command]).isEmpty else { return }
                self?.lastUserInputAt = ProcessInfo.processInfo.systemUptime
            }
        } as Any)
        // Frames sit above their window; let clicks in the transparent middle reach it.
        hoverMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassThrough() }
        } as Any)
        hoverMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateMousePassThrough() }; return event
        } as Any)
        // Raising any app can slip windows between a group and its frame; restack at once.
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateOverlays()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.updateOverlays() }
            }
        })
        if !system.accessibilityGranted { showSettings() }
    }
    func stop() {
        saveSession(); system.stop(); shortcuts.stop(); badges.stop(); desktopTimer?.invalidate(); settingsWatcher?.cancel()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        hoverMonitors.forEach(NSEvent.removeMonitor); hoverMonitors = []
        overlays.values.forEach { $0.close() }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Refresh right before showing, so the menu is never more than a moment out of date.
        updateGroupDesktops()
        menu.removeAllItems()
        addItem(menu, "TabWM", nil).isEnabled = false
        addItem(menu, paused ? "Resume Window Grouping" : "Pause Window Grouping", #selector(togglePause))
        addItem(menu, "Group Windows…", #selector(openPicker))
        if settings.searchEnabled { addItem(menu, "Search Tabs…", #selector(openSearch)) }
        menu.addItem(.separator())
        if !groups.isEmpty { addItem(menu, "Groups", nil).isEnabled = false }
        let labelled = groups.map { group in (group, groupDesktops[group.id] ?? "Unknown Desktop") }
        // One group per desktop is called after it; extra groups on the same desktop are numbered.
        var seen: [String: Int] = [:]
        for (group, desktop) in labelled.sorted(by: { $0.1.localizedStandardCompare($1.1) == .orderedAscending }) {
            seen[desktop, default: 0] += 1
            let sameDesktop = labelled.filter { $0.1 == desktop }.count
            let title = group.name ?? (sameDesktop > 1 ? "\(desktop) · Group \(seen[desktop]!)" : desktop)
            let item = addItem(menu, title, #selector(focusMenuGroup(_:)))
            item.representedObject = group.id.uuidString
            item.indentationLevel = 1
            let tabs = group.members.count
            item.toolTip = group.name == nil ? "\(tabs) tabs" : "\(desktop) · \(tabs) tabs"
            item.badge = NSMenuItemBadge(count: tabs)
        }
        if !groups.isEmpty { addItem(menu, "Ungroup All", #selector(ungroupAll)) }
        menu.addItem(.separator())
        addItem(menu, "Settings…", #selector(openSettings))
        addItem(menu, "Quit TabWM", #selector(quit))
    }
    /// Works out which desktop each group is on, as Mission Control names it ("Desktop 2").
    /// Desktops get renumbered when you add, remove, or reorder them, and windows move between
    /// them, so this runs every minute and after every Space switch. A group whose windows
    /// don't report a Space right now keeps its last known desktop.
    func updateGroupDesktops() {
        let desktops = SkyLight.shared.desktopNumbers()
        var labels: [UUID: String] = [:]
        for group in groups {
            let ids = [group.activeWindowID] + group.members.filter { $0 != group.activeWindowID }
            // Any member will do: they all share a Space, and hidden ones sometimes report none.
            if let space = ids.lazy.compactMap({ SkyLight.shared.space(of: $0) }).first {
                labels[group.id] = desktops[space].map { "Desktop \($0)" } ?? "Full Screen"
            } else if let known = groupDesktops[group.id] {
                labels[group.id] = known
            }
        }
        if labels != groupDesktops { groupDesktops = labels }
    }

    @discardableResult func addItem(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func togglePause() { paused.toggle(); updateOverlays() }
    @objc func openPicker() { showWindowPicker() }
    @objc func openSearch() { showSearch() }
    @objc func openSettings() { showSettings() }
    @objc func ungroupAll() { engine.dissolveAll() }
    @objc func focusMenuGroup(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let id = UUID(uuidString: raw), let group = groups.first(where: { $0.id == id }) { activate(group.activeWindowID) }
    }
    func window(_ id: UInt32) -> WindowInfo? { windows.first { $0.id == id } }
    /// Windows that can join a group. Fixed-size windows (System Settings, most panels with a
    /// disabled zoom button) are left alone: they can't take the group's shared size.
    var eligibleWindows: [WindowInfo] {
        windows.filter { !settings.excludedBundleIDs.contains($0.bundleID) && !$0.isFullscreen && !$0.isMinimized && !system.fixedSizeWindows.contains($0.id) }
    }
    /// Last title and app name seen per window, so a minimized or briefly missing tab keeps its label.
    var knownTitles: [UInt32: (title: String, app: String)] = [:]
    func tabTitle(_ id: UInt32) -> String {
        if let w = window(id) { return w.title.isEmpty ? w.appName : w.title }
        if let known = knownTitles[id] { return known.title.isEmpty ? known.app : known.title }
        return "Window"
    }
    var stageManagerEnabled:Bool { UserDefaults(suiteName:"com.apple.WindowManager")?.bool(forKey:"GloballyEnabled") ?? false }
    func refresh(_ found: [WindowInfo]) {
        let unavailable = system.censusUnavailablePIDs
        let old = windows
        let now = ProcessInfo.processInfo.systemUptime
        for w in found {
            if let previous = old.first(where:{$0.id == w.id}), previous.isMinimized != w.isMinimized { recentMinimizeChanges[w.id] = now }
        }
        recentMinimizeChanges = recentMinimizeChanges.filter { now - $0.value < 0.6 }
        windows = found + old.filter { prior in unavailable.contains(prior.pid) && !found.contains(where: { $0.id == prior.id }) }
        for w in found { knownTitles[w.id] = (w.title, w.appName) }
        // Windows seen for the first time (after the first census, which only records the
        // windows that already existed).
        let fresh = sawFirstCensus ? found.filter { !seenWindows.contains($0.id) } : []
        seenWindows = Set(found.map(\.id)).union(engine.groups.flatMap(\.members))
        if system.accessibilityGranted && !found.isEmpty { sawFirstCensus = true }
        let keep = Set(engine.groups.flatMap(\.members)).union(found.map(\.id))
        knownTitles = knownTitles.filter { keep.contains($0.key) }
        if !didRestore && system.accessibilityGranted && !found.isEmpty {
            if !Set(startupPIDs.values).isDisjoint(with:system.censusUnavailablePIDs), startupRestore != nil { return }
            didRestore = true
            if let saved = startupRestore {
                engine.restore(saved.map { group in
                    var group = group
                    group.members = group.members.filter { id in found.contains { $0.id == id && $0.pid == startupPIDs[id] } }
                    return group
                })
            }
            startupRestore = nil
            relayoutAll()
        }
        // While Mission Control is open (detected from the window list), leave windows alone.
        guard !paused, system.accessibilityGranted, !isSpaceTransitioning, !system.missionControlActive, !stageManagerEnabled else { updateOverlays(); return }
        reconcileNativeTabs(previous: old, now: now)
        engine.reconcile(windows: windows, settings: settings, preservingMissing: pendingNativeMembers.union(membersOnOtherSpaces(found)))
        reconcileSpaces()
        if let focused = system.focusedWindowID, let group = engine.group(containing: focused) {
            lastFocusedGroupAt[group.id] = now
            // Focus moved to another tab from outside TabWM (Dock, ⌘`, Mission Control). The
            // census runs in the background and can predate TabWM's own last tab switch;
            // trusting it then would switch straight back to the previous tab.
            if group.activeWindowID != focused, now - (lastActivation[group.id] ?? 0) > 1.5 { activate(focused) }
        }
        // A write has landed once it is a second old: whatever frame the window has now is
        // the one the app accepted.
        for (id, at) in recentWrites where now - at >= 1 {
            if let frame = WindowSystem.serverFrame(id) ?? window(id)?.frame { restingFrames[id] = frame }
        }
        recentWrites = recentWrites.filter { now - $0.value < 1.0 }
        let members = Set(engine.groups.flatMap(\.members))
        restingFrames = restingFrames.filter { members.contains($0.key) }
        if now < relayoutUntil { relayoutAll() } else { checkMembers() }
        if !fresh.isEmpty { autoGroup(fresh) }
        updateOverlays()
    }
    /// When the user last pressed a key, a modifier (⌃⌥⌘⇧, as window-manager shortcuts
    /// use), or the mouse outside TabWM.
    var lastUserInputAt: TimeInterval = 0
    var userActedRecently: Bool { ProcessInfo.processInfo.systemUptime - lastUserInputAt < 1.5 }
    /// Runs `checkMembers` once window events have been quiet for a moment.
    private var memberCheck: DispatchWorkItem?
    func scheduleMemberCheck() {
        memberCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkMembers(); self?.updateOverlays() } }
        memberCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    /// Groups never move or resize. For each member whose frame changed:
    /// - the user did it (title bar, edges, zoom, tiling or window-manager shortcuts): it
    ///   leaves the group and keeps its new frame;
    /// - the app did it on its own, or it was never placed: it is put back. If the app refuses
    ///   the size, the size it keeps is accepted (see `restingFrames`).
    /// The window's real frame comes from Accessibility, never from the window server alone:
    /// Mission Control and App Exposé report scaled thumbnails while they are open.
    func checkMembers() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !paused, system.accessibilityGranted, !isSpaceTransitioning, !system.missionControlActive, !stageManagerEnabled,
              NSEvent.pressedMouseButtons & 1 == 0, now >= relayoutUntil else { return }
        for group in engine.groups {
            // Fixed-size windows grouped earlier (or restored from a session) can't fill the group.
            if !group.isLocked, let fixed = group.members.first(where: { system.fixedSizeWindows.contains($0) }) {
                engine.detach(fixed)
                status = "\(window(fixed)?.appName ?? "A window") has a fixed size, so it was removed from the group."
                continue
            }
            // TabWM itself just switched tabs here; whatever followed came from that.
            let byUser = userActedRecently && now - (lastActivation[group.id] ?? 0) > 1
            for id in group.members where !group.suspended.contains(id) && !group.minimized.contains(id) && recentWrites[id] == nil {
                guard let w = window(id), w.isOnScreen, !w.isMinimized, !w.isFullscreen else { continue }
                if let server = WindowSystem.serverFrame(id), settled(server, id, group) { continue }
                guard let frame = system.liveFrame(id) else { continue }
                if settled(frame, id, group) { continue }
                // Entering native full screen: the window grows to the whole display first.
                if NSScreen.screens.contains(where: { near(CGRect(x: $0.frame.minX, y: primaryScreenHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height), frame) }) { continue }
                if byUser && !group.isLocked && restingFrames[id] != nil {
                    membershipLog.notice("\(w.appName, privacy: .public) left: \(String(describing: frame), privacy: .public) vs group \(String(describing: group.frame), privacy: .public)")
                    leave(id)
                } else {
                    membershipLog.notice("\(w.appName, privacy: .public) put back from \(String(describing: frame), privacy: .public)")
                    system.setFrameAsync(group.frame, for: id, priority: id == group.activeWindowID)
                    recentWrites[id] = now
                }
            }
        }
    }
    /// Whether `frame` is where this member belongs: the group frame, or the size the app
    /// settled at after TabWM's last write.
    func settled(_ frame: CGRect, _ id: UInt32, _ group: TabWMCore.WindowGroup) -> Bool {
        if near(frame, group.frame) { restingFrames[id] = frame; return true }
        return restingFrames[id].map { near($0, frame) } ?? false
    }
    /// Takes a window out of its group where it is. The rest of the group stays put; its
    /// frontmost remaining tab becomes the visible one without being raised over the window.
    func leave(_ id: UInt32) {
        guard let group = engine.group(containing: id) else { return }
        engine.detach(id)
        restingFrames[id] = nil
        guard group.activeWindowID == id, let other = group.members.first(where: { $0 != id }),
              let remaining = engine.group(containing: other),
              let top = WindowSystem.liveZOrder().first(where: { remaining.members.contains($0) }) else { return }
        engine.activate(top)
    }
    func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX)<2 && abs(a.minY-b.minY)<2 && abs(a.width-b.width)<2 && abs(a.height-b.height)<2
    }
    func reconcileNativeTabs(previous: [WindowInfo], now: TimeInterval) {
        var deferred = Set(recentMinimizeChanges.keys)
        // Includes local overlay gestures and global application window drags.
        if NSEvent.pressedMouseButtons & 1 != 0 { deferred.formUnion(engine.groups.flatMap(\.members)) }
        repointingNativeTabs = true
        let resolution = nativeTabs.reconcile(engine: engine,
            windows: windows.filter { !settings.excludedBundleIDs.contains($0.bundleID) },
            previousWindows: previous, confirmedHosts: system.nativeTabbedHosts,
            unknownHosts: system.nativeTabVerdictUnknownHosts,
            unavailablePIDs: system.censusUnavailablePIDs, deferredMembers: deferred,
            focusedWindowID: system.focusedWindowID, now: now)
        repointingNativeTabs = false
        pendingNativeMembers = resolution.preservedMembers
        for replacement in resolution.replacements {
            let id = replacement.window.id
            offSpaceSince.removeValue(forKey: replacement.oldID)
            recentMinimizeChanges.removeValue(forKey: replacement.oldID)
            guard let group = engine.group(containing: id),
                  !group.suspended.contains(id), !group.minimized.contains(id) else { continue }
            // A replacement window (native tab switch) takes the group's frame, never the
            // other way round; an inactive one is placed without raising the native host.
            system.setFrameAsync(group.frame, for: id, priority: group.activeWindowID == id)
            if let i = windows.firstIndex(where: { $0.id == id }) { windows[i].frame = group.frame }
            recentWrites[id] = now
        }
    }
    func engineChanged() {
        let previous = groups
        groups = engine.groups
        windowEvents.watch(Set(groups.flatMap(\.members)))
        if Set(previous.map(\.id)) != Set(groups.map(\.id)) { updateGroupDesktops() }
        for group in groups where !repointingNativeTabs {
            if let old = previous.first(where:{$0.id == group.id}), old.activeWindowID != group.activeWindowID,
               (window(old.activeWindowID) == nil || window(old.activeWindowID)?.isMinimized == true),
               !group.suspended.contains(group.activeWindowID), !group.minimized.contains(group.activeWindowID) {
                system.focus(group.activeWindowID)
            }
        }
        updateOverlays(); saveSession()
    }
    func saveSession() {
        guard didRestore else { return }
        if let data = try? JSONEncoder().encode(SavedSession(bootTime: Self.bootTime, groups: groups, pids: Dictionary(windows.map { ($0.id,$0.pid) },uniquingKeysWith:{a,_ in a}))) {
            try? data.write(to: storage.appendingPathComponent("session.json"), options: .atomic)
        }
    }
    func applySettings() {
        settings.normalize()
        if appliedLoginPreference != settings.launchAtLogin {
            let service = SMAppService.mainApp
            loginItemMessage = nil
            do {
                if settings.launchAtLogin && service.status == .notRegistered { try service.register() }
                else if !settings.launchAtLogin && service.status != .notRegistered { try service.unregister() }
                if settings.launchAtLogin && service.status == .requiresApproval { loginItemMessage = "Approve TabWM in System Settings → General → Login Items." }
            } catch {
                settings.launchAtLogin = service.status == .enabled
                // Ad-hoc signed builds outside /Applications are commonly refused by macOS.
                loginItemMessage = "macOS refused to add TabWM as a login item. Move TabWM.app to /Applications and try again, or add it in System Settings → General → Login Items."
            }
            appliedLoginPreference = settings.launchAtLogin
        }
        writeSettingsFile()
        if statusItem != nil { shortcuts.configure(settings) }
        // A taller strip or wider border changes the area every group fills.
        let metrics = CGSize(width: settings.frameThickness, height: settings.tabBarHeight)
        if metrics != appliedMetrics { appliedMetrics = metrics; relayoutAll() }
        NSApp.appearance = settings.appearance == "dark" ? NSAppearance(named: .darkAqua) : settings.appearance == "light" ? NSAppearance(named: .aqua) : nil
        updateOverlays()
    }
    // MARK: Settings file

    /// Every choice the Settings window offers, in TabWM's readable TOML format (the same
    /// file Export writes). The app reads it at launch, writes it whenever a setting changes,
    /// and picks up edits made to it while running.
    var settingsURL: URL { configDirectory.appendingPathComponent("settings.toml") }
    /// The XDG Base Directory config location: $XDG_CONFIG_HOME when set to an absolute path,
    /// otherwise ~/.config.
    static var xdgConfigDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var base = home.appendingPathComponent(".config", isDirectory: true)
        if let custom = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], custom.hasPrefix("/") {
            base = URL(fileURLWithPath: custom, isDirectory: true)
        }
        return base.appendingPathComponent("TabWM", isDirectory: true)
    }
    /// What the file held when TabWM last wrote or read it, so its own writes aren't reloaded.
    var settingsFileSnapshot: Data?
    var settingsWatcher: DispatchSourceFileSystemObject?

    /// Settings from an older build's settings.json (Application Support or ~/.config), which
    /// is removed once read: settings.toml replaces it.
    static func legacySettings(storage: URL, config: URL) -> AppSettings? {
        for url in [config.appendingPathComponent("settings.json"), storage.appendingPathComponent("settings.json")] {
            guard let data = try? Data(contentsOf: url), var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { continue }
            settings.normalize()
            try? FileManager.default.removeItem(at: url)
            return settings
        }
        return nil
    }
    func writeSettingsFile() {
        let data = SettingsFile.data(settings)
        guard data != settingsFileSnapshot else { return }
        settingsFileSnapshot = data
        try? data.write(to: settingsURL, options: .atomic)
        // An atomic write replaces the file, which ends the old watch.
        watchSettingsFile()
    }
    /// Puts every setting back to TabWM's defaults.
    func restoreDefaultSettings() {
        settings = AppSettings()
        applySettings()
        status = "Settings restored to their defaults."
    }
    /// Re-reads settings.toml after it changes on disk (edited by hand, synced, replaced).
    func watchSettingsFile() {
        settingsWatcher?.cancel(); settingsWatcher = nil
        let descriptor = open(settingsURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Editors save by replacing the file; give them a moment to finish.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.reloadSettingsFile() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        settingsWatcher = source
    }
    func reloadSettingsFile() {
        defer { watchSettingsFile() }
        guard let data = try? Data(contentsOf: settingsURL), data != settingsFileSnapshot else { return }
        let loaded: AppSettings
        do { loaded = try SettingsFile.settings(from: data) } catch {
            status = "settings.toml has a mistake, so TabWM kept its current settings. \(error.localizedDescription)"
            return
        }
        settingsFileSnapshot = data
        if loaded != settings { settings = loaded; applySettings() }
        status = "Settings reloaded from settings.toml."
    }
    func revealSettingsFile() {
        writeSettingsFile()
        NSWorkspace.shared.activateFileViewerSelecting([settingsURL])
    }

    /// Window IDs present in the last census, to spot newly opened windows.
    var seenWindows: Set<UInt32> = []
    var sawFirstCensus = false
    /// When each group last had focus, to pick "the group you were working in".
    var lastFocusedGroupAt: [UUID: TimeInterval] = [:]

    /// Puts newly opened windows into a group, as set in Grouping → New windows.
    /// Only standard, resizable, visible windows on the current Space qualify, and never a
    /// window that opened as part of a drag (the drag decides where it goes).
    func autoGroup(_ fresh: [WindowInfo]) {
        guard settings.newWindowPolicy != "off", !engine.groups.isEmpty, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        for w in fresh {
            guard eligibleWindows.contains(where: { $0.id == w.id }), w.isOnScreen,
                  engine.group(containing: w.id) == nil else { continue }
            let candidates = engine.groups.filter { group in
                !group.isLocked && group.members.contains { id in window(id).map { $0.isOnScreen && !$0.isMinimized } ?? false }
            }
            // The group you were working in: the most recently focused visible group.
            let target = candidates.max { (lastFocusedGroupAt[$0.id] ?? 0) < (lastFocusedGroupAt[$1.id] ?? 0) }
            guard let target, let anchor = window(target.activeWindowID) else { continue }
            engine.group(w, with: anchor)
            layoutGroup(containing: w.id)
            activate(w.id)
        }
    }
    /// Members of groups that are entirely off the current Space. Some apps stop listing
    /// windows that are on another Space, so without this they'd look closed and be dropped.
    /// A window that is really closed vanishes from the window server, so it isn't kept.
    func membersOnOtherSpaces(_ found: [WindowInfo]) -> Set<UInt32> {
        let listed = Set(found.map(\.id))
        var keep = Set<UInt32>()
        for group in engine.groups {
            let visible = group.members.contains { id in found.first(where: { $0.id == id }).map { $0.isOnScreen && !$0.isMinimized } ?? false }
            guard !visible else { continue }
            for id in group.members where !listed.contains(id) && WindowSystem.serverFrame(id) != nil { keep.insert(id) }
        }
        return keep
    }
    func reconcileSpaces() {
        // Right after a Space switch windows can report off-screen while the switch animates.
        let settling = ProcessInfo.processInfo.systemUptime - spaceSettledAt < 2
        guard settings.offSpacePolicy == "detach", !settling, ProcessInfo.processInfo.systemUptime >= displayRecoveryUntil else { offSpaceSince = [:]; return }
        let now = ProcessInfo.processInfo.systemUptime
        var candidates = Set<UInt32>()
        for group in engine.groups where !group.isLocked {
            let home = group.members.contains { id in
                guard let w = window(id) else { return false }; return w.isOnScreen && !w.isMinimized && !w.isFullscreen
            }
            guard home else { continue }
            for id in group.members {
                guard let w = window(id), !w.isOnScreen, !w.isMinimized, !w.isFullscreen,
                      NSRunningApplication(processIdentifier:w.pid)?.isHidden != true,
                      !system.censusUnavailablePIDs.contains(w.pid),
                      recentMinimizeChanges[id] == nil,
                      !pendingNativeMembers.contains(id) else { continue }
                candidates.insert(id)
                if offSpaceSince[id] == nil { offSpaceSince[id] = now }
                if now - (offSpaceSince[id] ?? now) >= 1 { engine.detach(id) }
            }
        }
        offSpaceSince = offSpaceSince.filter { candidates.contains($0.key) }
    }
    func makeGroup(_ source: UInt32, _ target: UInt32) {
        guard !stageManagerEnabled else { status="Turn off Stage Manager to group windows.";return }
        guard let a = window(source), let b = window(target), !settings.excludedBundleIDs.contains(a.bundleID), !settings.excludedBundleIDs.contains(b.bundleID) else { return }
        if let fixed = [a, b].first(where: { system.fixedSizeWindows.contains($0.id) }) {
            status = "\(fixed.appName) has a fixed-size window and can't be grouped."; return
        }
        engine.group(a, with: b)
        // The joining window takes the group's fixed frame, whatever its own size was.
        guard engine.group(containing: source) != nil else { return }
        layoutGroup(containing: source); activate(source)
    }
    /// When TabWM last switched each group's tab, to tell our own restacking from the user's.
    var lastActivation: [UUID: TimeInterval] = [:]
    func activate(_ id: UInt32) {
        if let group = engine.group(containing: id) { lastActivation[group.id] = ProcessInfo.processInfo.systemUptime }
        engine.activate(id); system.focus(id); updateOverlays()
    }
    /// The group the user is working in: the focused window's group, otherwise the
    /// frontmost visible group in window order.
    var focusedGroup: TabWMCore.WindowGroup? {
        if let focused = system.focusedWindowID, let group = engine.group(containing: focused) { return group }
        for id in system.zOrder { if let group = engine.group(containing: id), overlays[group.id]?.isVisible == true { return group } }
        return nil
    }
    func cycle(forward: Bool) {
        guard let group = focusedGroup else { return }
        let candidates = group.members.filter { !group.suspended.contains($0) && !group.minimized.contains($0) }
        guard candidates.count > 1, let index = candidates.firstIndex(of: group.activeWindowID) else { return }
        let next = candidates[(index + (forward ? 1 : candidates.count - 1)) % candidates.count]
        activate(next)
    }
    func perform(_ action: ShortcutAction) {
        guard !paused else { return }
        switch action {
        case .nextTab: cycle(forward: true)
        case .previousTab: cycle(forward: false)
        case .search: showSearch()
        case .groupAll: groupAllOnCurrentSpace()
        case .addTab:
            // Without a group to add to, the picker makes a new group instead.
            if let group = focusedGroup, !group.isLocked { showWindowPicker(target: group.activeWindowID) } else { showWindowPicker() }
        case .ungroup: if let group = focusedGroup, !group.isLocked { engine.dissolve(group.id) }
        }
    }
    /// Groups every eligible visible window on the current Space into one group: the
    /// focused group (or focused window) absorbs the rest.
    func groupAllOnCurrentSpace() {
        guard !stageManagerEnabled else { status = "Turn off Stage Manager to group windows."; return }
        let order = WindowSystem.liveZOrder()
        // On-screen windows are the ones on the current Space (and not minimized/hidden).
        let visible = eligibleWindows.filter { $0.isOnScreen && order.contains($0.id) }
            .sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        guard visible.count >= 2 else { status = "There are fewer than two windows on this Space."; return }
        let anchorID = focusedGroup?.activeWindowID ?? system.focusedWindowID.flatMap { id in visible.first { $0.id == id }?.id } ?? visible[0].id
        guard let anchor = window(anchorID), engine.group(containing: anchorID)?.isLocked != true else { return }
        for w in visible where w.id != anchorID && engine.group(containing: w.id)?.isLocked != true {
            if let current = engine.group(containing: anchorID), current.members.contains(w.id) { continue }
            engine.group(w, with: anchor)
        }
        guard engine.group(containing: anchorID) != nil else { return }
        engine.activate(anchorID)
        layoutGroup(containing: anchorID)
        system.focus(anchorID); updateOverlays()
    }
    /// Every group fills its screen's usable area: below the menu bar, above the Dock, inside
    /// the tab strip and border. Gives each available member that frame. Writes are
    /// asynchronous so a slow app never blocks the UI.
    func layoutGroup(containing id: UInt32, on target: NSScreen? = nil) {
        guard let group = engine.group(containing: id), let screen = target ?? screen(containing: group.frame) else { return }
        let frame = windowArea(of: screen)
        if !near(group.frame, frame) { engine.updateFrame(id, frame: frame) }
        let now = ProcessInfo.processInfo.systemUptime
        for member in group.members where !group.suspended.contains(member) && !group.minimized.contains(member) {
            if let current = WindowSystem.serverFrame(member) ?? window(member)?.frame, near(current, frame) {
                restingFrames[member] = current; continue
            }
            system.setFrameAsync(frame, for: member, priority: member == group.activeWindowID)
            recentWrites[member] = now
        }
        updateOverlays()
    }
    /// Re-fits every group to its screen (display changes, strip or border size changes).
    func relayoutAll() {
        guard system.accessibilityGranted else { return }
        for group in engine.groups { layoutGroup(containing: group.activeWindowID) }
    }
    func closeTab(_ id: UInt32) { system.close(id) }
    func detachTab(_ id:UInt32) {
        guard let old=engine.group(containing:id),!old.isLocked else{return}
        engine.detach(id)
        if old.activeWindowID == id,let remaining=groups.first(where:{$0.id==old.id}),!remaining.suspended.contains(remaining.activeWindowID),!remaining.minimized.contains(remaining.activeWindowID){system.focus(remaining.activeWindowID)}
    }
    func closeGroup(_ group: TabWMCore.WindowGroup) {
        let alert = NSAlert(); alert.messageText = "Close all \(group.members.count) windows?"; alert.informativeText = "Applications may ask you to save changes."; alert.addButton(withTitle: "Close Windows"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { group.members.forEach(system.close) }
    }
    func moveGroup(_ group: TabWMCore.WindowGroup, to screen: NSScreen) {
        layoutGroup(containing: group.activeWindowID, on: screen); system.focus(group.activeWindowID)
    }

    // MARK: Group frame geometry (Accessibility coordinates, top-left origin)

    var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    func screen(containing frame: CGRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: primaryScreenHeight - frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }
    /// The screen's visible area in Accessibility coordinates.
    func visibleArea(of screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame
        return CGRect(x: v.minX, y: primaryScreenHeight - v.maxY, width: v.width, height: v.height)
    }
    /// The area a group's *window* may occupy on a screen: the visible frame (no menu bar,
    /// no Dock) minus the tab strip on top and the border on the other sides.
    func windowArea(of screen: NSScreen) -> CGRect {
        let a = visibleArea(of: screen), t = settings.frameThickness, bar = settings.tabBarHeight
        return CGRect(x: a.minX + t, y: a.minY + bar, width: a.width - 2 * t, height: a.height - bar - t)
    }
    /// A grouped window moved, resized, or was restacked, reported by the window server the
    /// moment it happens. Groups never move; `checkMembers` decides what a moved or resized
    /// member means.
    func handleWindowEvent(_ event: SkyLight.Event, _ id: UInt32) {
        switch event {
        case .frontAppChanged:
            updateOverlays()
            // New windows usually appear right after their app comes forward; look now
            // rather than at the next safety-net census.
            if settings.newWindowPolicy != "off" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.system.refresh() }
            }
        case .windowDestroyed:
            if engine.group(containing: id) != nil { system.refresh() }
        case .windowReordered:
            guard let group = engine.group(containing: id) else { return }
            if group.activeWindowID == id { if let panel = overlays[group.id], panel.isVisible { panel.restack() }; return }
            // A hidden tab was brought forward by something else (Dock, ⌘`, Mission Control):
            // make it the tab. Ignore the echoes of our own tab switches.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - (lastActivation[group.id] ?? 0) > 1,
                  WindowSystem.liveZOrder().first(where: { group.members.contains($0) }) == id else { return }
            activate(id)
        case .windowMoved, .windowResized:
            // Decide once the window stops changing (mid-drag, the mouse-up check decides).
            if engine.group(containing: id) != nil, recentWrites[id] == nil { scheduleMemberCheck() }
        }
    }
    /// On a Space switch, show each group's strip whose visible window is on the arriving Space
    /// and hide the rest, using the window server's live list. The census (which decides
    /// membership) is taken later, once the switch settles.
    func showStripsForCurrentSpace() {
        guard !paused, !stageManagerEnabled, system.accessibilityGranted else { return }
        let onScreen = Set(WindowSystem.liveZOrder())
        for group in groups {
            guard let panel = overlays[group.id] else { continue }
            if onScreen.contains(group.activeWindowID), let frame = WindowSystem.serverFrame(group.activeWindowID) {
                panel.place(around: frame, windowID: group.activeWindowID)
                panel.orderFront(nil)
                panel.restack()
            } else {
                panel.orderOut(nil)
            }
        }
    }
    func updateMousePassThrough() {
        let mouse = NSEvent.mouseLocation
        for panel in overlays.values where panel.isVisible { panel.ignoresMouseEvents = panel.holeRect.contains(mouse) }
    }
    func rename(_ group: TabWMCore.WindowGroup) {
        let alert = NSAlert(); alert.messageText = "Name Group"; let field = NSTextField(string: group.name ?? ""); field.frame = NSRect(x:0,y:0,width:260,height:24); alert.accessoryView = field; alert.addButton(withTitle:"Save");alert.addButton(withTitle:"Cancel")
        if alert.runModal() == .alertFirstButtonReturn { engine.rename(group.id,name:field.stringValue) }
    }
    func updateOverlays() {
        guard statusItem != nil else { return }
        let ids = Set(groups.map(\.id))
        for id in Array(overlays.keys) where !ids.contains(id) { overlays.removeValue(forKey:id)?.close() }
        for group in groups {
            let panel = overlays[group.id] ?? GroupFramePanel(controller:self,groupID:group.id)
            overlays[group.id] = panel
            if paused || stageManagerEnabled || !system.accessibilityGranted {
                panel.orderOut(nil)
            } else if isSpaceTransitioning {
                // `showStripsForCurrentSpace` already placed this Space's strips.
                continue
            } else if !group.members.contains(where: { id in
                guard let w = window(id) else { return false }; return w.isOnScreen && !w.isMinimized && !w.isFullscreen && !group.suspended.contains(id)
            }) {
                panel.orderOut(nil)
            } else { panel.update(group) }
        }
    }
    func showSettings() {
        if settingsWindow == nil { settingsWindow = hostWindow(title:"TabWM Settings",size:NSSize(width:900,height:720),view:SettingsView(controller:self)) }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func showSearch() {
        guard settings.searchEnabled else { return }
        searchWindow?.close()
        searchWindow = GlassPanel.make(size:NSSize(width:760,height:500),view:SearchView(controller:self))
        NSApp.activate(ignoringOtherApps:true); searchWindow?.makeKeyAndOrderFront(nil)
    }
    func showWindowPicker(target: UInt32? = nil) {
        system.refresh()
        windowPicker?.close()
        windowPicker = GlassPanel.make(size:NSSize(width:760,height:500),view:WindowPickerView(controller:self,target:target))
        NSApp.activate(ignoringOtherApps:true); windowPicker?.makeKeyAndOrderFront(nil)
    }
    func hostWindow<V:View>(title:String,size:NSSize,view:V)->NSWindow {
        let w = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        w.title=title;w.titlebarAppearsTransparent=true;w.toolbarStyle = .unified
        w.isReleasedWhenClosed=false;w.contentView=NSHostingView(rootView:view);w.center();return w
    }
    /// Saves every setting to a JSON file (see `SettingsFile` for the layout).
    func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TabWM Settings.toml"
        panel.allowedContentTypes = [Self.tomlType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsFile.save(settings, to: url)
            status = "Settings exported to \(url.lastPathComponent)."
        } catch { status = "Could not export settings: \(error.localizedDescription)" }
    }
    /// Replaces every setting with the file's. Settings missing from the file get their defaults.
    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.tomlType, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            settings = try SettingsFile.load(from: url)
            // applySettings writes the imported values to settings.toml, which every part of
            // TabWM reads from.
            applySettings()
            status = "Settings imported from \(url.lastPathComponent)."
        } catch { status = "Could not import settings: \(error.localizedDescription)" }
    }
    static let tomlType = UTType(filenameExtension: "toml", conformingTo: .plainText) ?? .plainText
    func trackDrag(_ event:NSEvent) {
        guard !paused,system.accessibilityGranted,!stageManagerEnabled else { hidePreview();return }
        let point=NSEvent.mouseLocation
        let h=NSScreen.screens.first?.frame.height ?? 0
        let ax=CGPoint(x:point.x,y:h-point.y)
        lastUserInputAt=ProcessInfo.processInfo.systemUptime
        switch event.type {
        case .leftMouseDown:
            dragStart=point
            // Fresh order: the click may have just raised this window above a maximized group.
            let order=WindowSystem.liveZOrder()
            dragSource=order.first(where:{id in eligibleWindows.contains(where:{$0.id==id && (WindowSystem.serverFrame(id) ?? $0.frame).contains(ax)})})
            dragOriginalFrame=dragSource.flatMap{WindowSystem.serverFrame($0) ?? window($0)?.frame}
            dragOrder=order
            dragTarget=nil;candidateSince=nil
        case .leftMouseDragged:
            guard let source=dragSource, let start=dragStart, hypot(point.x-start.x,point.y-start.y)>8, modifierMatches(event.modifierFlags) else { hidePreview();return }
            guard let original=dragOriginalFrame,let live=WindowSystem.serverFrame(source) ?? window(source)?.frame, hypot(original.minX-live.minX,original.minY-live.minY)>4 else { hidePreview();return }
            let sourceGroup=engine.group(containing:source)
            // The tab strip of a group is a drop target too; for a maximized group it is the
            // most natural one, since its window fills the rest of the screen.
            let strip=overlays.values.first{ $0.isVisible && $0.barRect.contains(point) && sourceGroup?.id != $0.groupID }
            let stripTarget=strip.flatMap{p in groups.first{$0.id==p.groupID}}.flatMap{window($0.activeWindowID)}
            let target=stripTarget ?? dragOrder.compactMap(window).first { w in w.id != source && !settings.excludedBundleIDs.contains(w.bundleID) && !system.fixedSizeWindows.contains(w.id) && !w.isMinimized && !w.isFullscreen && (WindowSystem.serverFrame(w.id) ?? w.frame).contains(ax) && sourceGroup?.members.contains(w.id) != true }
            guard let target,engine.group(containing:target.id)?.isLocked != true else { hidePreview();return }
            if dragTarget != target.id { preview?.orderOut(nil);dragTarget=target.id;candidateSince=Date() }
            if Date().timeIntervalSince(candidateSince ?? Date())>=settings.holdDelay {
                // Highlight the whole group (strip included) when joining one.
                if let panel=engine.group(containing:target.id).flatMap({overlays[$0.id]}), panel.isVisible {
                    showPreview(CGRect(x:panel.frame.minX,y:h-panel.frame.maxY,width:panel.frame.width,height:panel.frame.height))
                } else { showPreview(WindowSystem.serverFrame(target.id) ?? target.frame) }
            }
        case .leftMouseUp:
            if preview?.isVisible == true,let source=dragSource,let target=dragTarget,modifierMatches(event.modifierFlags) { makeGroup(source,target) }
            hidePreview();dragSource=nil;dragStart=nil
            // A member dragged or resized by its title bar or edges leaves as soon as it's let go.
            scheduleMemberCheck()
        default: break
        }
    }
    func finishTabDrag(id:UInt32,at point:NSPoint) {
        guard let original=engine.group(containing:id),!original.isLocked else{return}
        if let panel=overlays.values.first(where:{$0.isVisible && $0.barRect.contains(point)}),
           let target=groups.first(where:{$0.id==panel.groupID}),!target.isLocked {
            // Insert before the first tab whose midpoint lies right of the pointer.
            let localX=point.x-panel.frame.minX
            let others=target.members.filter{$0 != id}
            let index=others.firstIndex{ (tabFrames[$0]?.midX ?? .infinity) > localX } ?? others.count
            if target.id == original.id { engine.reorder(id,to:index);activate(id);return }
            engine.moveMember(id,to:target.activeWindowID,atIndex:index)
            layoutGroup(containing:id);activate(id)
            return
        }
        guard let w=window(id) else{return}
        engine.detach(id)
        let h=NSScreen.screens.first?.frame.height ?? 0
        var frame=w.frame;frame.origin=CGPoint(x:point.x-60,y:h-point.y)
        system.setFrame(frame,for:id);system.focus(id)
    }
    func modifierMatches(_ flags:NSEvent.ModifierFlags)->Bool {
        switch settings.modifier {
        case "none": return true
        case "shift": return flags.contains(.shift)
        case "control": return flags.contains(.control)
        case "option": return flags.contains(.option)
        case "command": return flags.contains(.command)
        default: return leaderHeld(flags)
        }
    }
    /// Whether the leader key is physically held. Event flags are unreliable for Globe and
    /// can't tell left from right modifiers, so ask the window server for the live state.
    func leaderHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        let live = CGEventSource.flagsState(.combinedSessionState)
        switch settings.leaderKey {
        case "globe": return live.contains(.maskSecondaryFn) || flags.contains(.function)
        case "rightCommand": return live.rawValue & 0x10 != 0
        case "rightOption": return live.rawValue & 0x40 != 0
        case "rightControl": return live.rawValue & 0x2000 != 0
        case "off": return flags.contains(.shift)
        default:
            let chord = AppSettings.leaderChords[settings.leaderKey] ?? 0
            var held: UInt32 = 0
            if flags.contains(.command) { held |= KeyModifier.command }; if flags.contains(.shift) { held |= KeyModifier.shift }
            if flags.contains(.option) { held |= KeyModifier.option }; if flags.contains(.control) { held |= KeyModifier.control }
            return chord != 0 && held & chord == chord
        }
    }
    /// Display name of the grouping key, for Settings and How to Use.
    var groupingKeyName: String {
        switch settings.modifier {
        case "shift": return "⇧ Shift"
        case "control": return "⌃ Control"
        case "option": return "⌥ Option"
        case "command": return "⌘ Command"
        case "none": return "no key"
        default: return settings.leaderKey == "off" ? "⇧ Shift" : KeyNames.leader(settings.leaderKey)
        }
    }
    func hidePreview(){preview?.orderOut(nil);dragTarget=nil;candidateSince=nil}
    func showPreview(_ frame:CGRect) {
        if preview == nil {
            let p=NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            p.level = .floating;p.isOpaque=false;p.backgroundColor = .clear;p.hasShadow=false;p.ignoresMouseEvents=true
            p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            let host=NSHostingView(rootView:GroupDropPreview());host.sizingOptions=[];p.contentView=host;preview=p
        }
        let h=NSScreen.screens.first?.frame.height ?? 0
        preview?.setFrame(NSRect(x:frame.minX,y:h-frame.maxY,width:frame.width,height:frame.height),display:true);preview?.orderFrontRegardless()
    }
}

extension Array where Element: Hashable { func uniqued()->[Element] { var seen=Set<Element>();return filter{seen.insert($0).inserted} } }
