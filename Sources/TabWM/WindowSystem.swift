import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Darwin
import TabWMCore

/// Latest-wins Accessibility frame writer. One pending job per window; repeated requests
/// collapse into whichever frame is current when the queue gets to it.
/// Each app gets its own serial queue, so one slow app never delays another app's windows.
/// Writes size, position, size, so a window growing toward a screen edge isn't clamped by
/// its old position.
final class FrameWriter: @unchecked Sendable {
    private struct Job { var element: AXUIElement; var pid: Int32; var frame: CGRect }
    private let lock = NSLock()
    private var pending: [UInt32: Job] = [:]
    private var queues: [Int32: DispatchQueue] = [:]
    private func queue(for pid: Int32) -> DispatchQueue {
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "dev.tabwm.frame-writer.\(pid)", qos: .userInteractive)
        queues[pid] = queue; return queue
    }
    func submit(id: UInt32, pid: Int32, element: AXUIElement, frame: CGRect, priority: Bool) {
        lock.lock()
        let schedule = pending[id] == nil
        pending[id] = Job(element: element, pid: pid, frame: frame)
        let queue = queue(for: priority ? Int32.min : pid)
        lock.unlock()
        if schedule { queue.async { self.run(id) } }
    }
    private func run(_ id: UInt32) {
        lock.lock(); let job = pending.removeValue(forKey: id); lock.unlock()
        guard let job else { return }
        AXUIElementSetMessagingTimeout(job.element, 0.25)
        var position = job.frame.origin, size = job.frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // Apps with AXEnhancedUserInterface on (often set by other assistive tools) animate
        // every frame change; switch it off around the write.
        let app = AXUIElementCreateApplication(job.pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        let enhanced = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &value) == .success && (value as? Bool) == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(job.element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(job.element, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(job.element, kAXSizeAttribute as CFString, sizeValue)
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }
}

@MainActor
final class WindowSystem {
    var onRefresh: (([WindowInfo]) -> Void)?
    private(set) var windows: [WindowInfo] = []
    private(set) var missionControlActive = false
    private(set) var nativeTabbedHosts: Set<UInt32> = []
    private(set) var nativeTabVerdictUnknownHosts: Set<UInt32> = []
    private(set) var lastError: String?
    /// Only standard windows in this census can be focused here. Dialog focus,
    /// inaccessible apps, and our own panels produce nil rather than a guessed ID.
    private(set) var focusedWindowID: UInt32?
    /// CG window order, front to back; includes windows not eligible for grouping.
    private(set) var zOrder: [UInt32] = []
    /// An incomplete AX census must not be interpreted as windows having closed.
    private(set) var censusUnavailablePIDs: Set<Int32> = []
    /// Windows confirmed resizable (cached), and windows currently reporting a fixed size.
    private(set) var resizableWindows: Set<UInt32> = []
    private(set) var fixedSizeWindows: Set<UInt32> = []
    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    private var elements: [UInt32: AXUIElement] = [:]
    private var timer: Timer?
    private typealias GetWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    nonisolated private static let getWindowID: GetWindowID? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowID.self)
    }()

    /// Full-census interval. With window-server events active the census is only a safety
    /// net for titles, minimizing, and new windows, so it can run much less often.
    var pollInterval: TimeInterval = 0.35 {
        didSet { guard pollInterval != oldValue, timer != nil else { return }; timer?.invalidate(); timer = nil; start() }
    }
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        scanGeneration &+= 1
        refreshPending = false
        // Keep scanInFlight until the existing serial scan completes. A subsequent
        // start/explicit refresh coalesces behind it instead of spawning another.
    }

    nonisolated private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(kAXPositionAttribute, of: element), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(kAXSizeAttribute, of: element), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
    private let censusQueue = DispatchQueue(label: "dev.tabwm.window-census", qos: .userInitiated)
    private var scanInFlight = false
    private var refreshPending = false
    private var scanGeneration: UInt64 = 0
    private struct AppIdentity: Sendable {
        var processIdentifier: Int32
        var name: String
        var bundleID: String
        var processStartedAt: TimeInterval?
    }
    private struct CensusInput: Sendable {
        var apps: [AppIdentity]
        var frontmostPID: Int32?
        var screenSizes: [CGSize]
        /// Windows already known to be resizable; only unknown or fixed ones are re-checked.
        var knownResizable: Set<UInt32>
    }
    // AX references are produced exclusively on the serial queue, then handed
    // off with the complete snapshot. The scanner never mutates published state.
    private struct CensusResult: @unchecked Sendable {
        var windows: [WindowInfo]
        var elements: [UInt32: AXUIElement]
        var focusedWindowID: UInt32?
        var zOrder: [UInt32]
        var unavailablePIDs: Set<Int32>
        var resizable: Set<UInt32>
        var missionControlActive: Bool
        var nativeTabbedHosts: Set<UInt32>
        var nativeTabVerdictUnknownHosts: Set<UInt32>
    }
    func refresh() {
        guard accessibilityGranted else {
            scanGeneration &+= 1
            refreshPending = false
            elements = [:]; windows = []; focusedWindowID = nil; zOrder = []
            missionControlActive = false; nativeTabbedHosts = []; nativeTabVerdictUnknownHosts = []
            censusUnavailablePIDs = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
            lastError = "Accessibility permission is required to manage windows."
            onRefresh?(windows); return
        }
        guard !scanInFlight else { refreshPending = true; return }
        let input = CensusInput(
            apps: NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.map {
                AppIdentity(processIdentifier: $0.processIdentifier, name: $0.localizedName ?? "App", bundleID: $0.bundleIdentifier ?? "", processStartedAt: $0.launchDate?.timeIntervalSince1970)
            },
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            screenSizes: NSScreen.screens.map { $0.frame.size },
            knownResizable: resizableWindows)
        let generation = scanGeneration
        scanInFlight = true
        censusQueue.async { [weak self] in
            let result = Self.scan(input)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scanInFlight = false
                let completionGeneration = self.scanGeneration
                let pending = self.refreshPending
                self.refreshPending = false
                if generation == self.scanGeneration {
                    if self.accessibilityGranted {
                        self.elements = result.elements
                        self.windows = result.windows
                        self.focusedWindowID = result.focusedWindowID
                        self.zOrder = result.zOrder
                        self.censusUnavailablePIDs = result.unavailablePIDs
                        self.resizableWindows = result.resizable
                        self.fixedSizeWindows = Set(result.windows.map(\.id)).subtracting(result.resizable)
                        self.missionControlActive = result.missionControlActive
                        self.nativeTabbedHosts = result.nativeTabbedHosts
                        self.nativeTabVerdictUnknownHosts = result.nativeTabVerdictUnknownHosts
                        if self.lastError == "Accessibility permission is required to manage windows." || self.lastError == "Accessibility permission has been revoked." { self.lastError = nil }
                        self.onRefresh?(self.windows)
                    } else {
                        self.refresh()
                    }
                }
                // A callback may stop the service; don't resurrect its queued refresh.
                if pending && completionGeneration == self.scanGeneration { self.refresh() }
            }
        }
    }
    nonisolated private static func scan(_ input: CensusInput) -> CensusResult {
        guard let records = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return CensusResult(windows: [], elements: [:], focusedWindowID: nil, zOrder: [],
                                unavailablePIDs: Set(input.apps.map(\.processIdentifier)), resizable: input.knownResizable, missionControlActive: false, nativeTabbedHosts: [], nativeTabVerdictUnknownHosts: [])
        }
        // Mission Control and App Exposé draw a screen-sized Dock window above everything.
        let missionControlActive = records.contains { record in
            guard record[kCGWindowOwnerName as String] as? String == "Dock",
                  record[kCGWindowIsOnscreen as String] as? Bool == true,
                  let layer = record[kCGWindowLayer as String] as? NSNumber,
                  layer.int32Value != CGWindowLevelForKey(.dockWindow),
                  let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation:bounds) else { return false }
            return input.screenSizes.contains { frame.width >= $0.width * 0.9 && frame.height >= $0.height * 0.9 }
        }
        let zOrder = records.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        var censusUnavailablePIDs: Set<Int32> = []
        var focusedWindowID: UInt32?
        let frontmostPID = input.frontmostPID
        var nativeTabbedHosts: Set<UInt32> = []
        var nativeTabVerdictUnknownHosts: Set<UInt32> = []
        var found: [WindowInfo] = [], nextElements: [UInt32: AXUIElement] = [:]
        var resizable: Set<UInt32> = []
        for app in input.apps {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.05)
            guard let appWindows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] else {
                censusUnavailablePIDs.insert(app.processIdentifier); continue
            }
            let focused = app.processIdentifier == frontmostPID ? attribute(kAXFocusedWindowAttribute, of: application) : nil
            let candidates = records.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
            for element in appWindows {
                guard let role = attribute(kAXRoleAttribute, of: element) as? String,
                      let subrole = attribute(kAXSubroleAttribute, of: element) as? String else {
                    censusUnavailablePIDs.insert(app.processIdentifier); continue
                }
                // Strict eligibility intentionally excludes sheets, dialogs and custom
                // window subroles. Some apps omit subroles and cannot be grouped.
                guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole else { continue }
                guard let rect = frame(of: element), rect.width > 1, rect.height > 1 else {
                    censusUnavailablePIDs.insert(app.processIdentifier); continue
                }
                let title = attribute(kAXTitleAttribute, of: element) as? String ?? ""
                var id: UInt32 = 0
                if getWindowID?(element, &id) != .success || id == 0 {
                    // Only accept an unambiguous exact geometry match; never control a guessed window.
                    let matches = candidates.filter { record in
                        guard let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                              let cgRect = CGRect(dictionaryRepresentation: bounds) else { return false }
                        return abs(cgRect.minX - rect.minX) < 2 && abs(cgRect.minY - rect.minY) < 2 && abs(cgRect.width - rect.width) < 2 && abs(cgRect.height - rect.height) < 2
                    }
                    guard matches.count == 1, let number = matches[0][kCGWindowNumber as String] as? NSNumber else {
                        censusUnavailablePIDs.insert(app.processIdentifier); continue
                    }
                    id = number.uint32Value
                }
                guard nextElements[id] == nil else { continue }
                let record = candidates.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
                let minimized = (attribute(kAXMinimizedAttribute, of: element) as? Bool) ?? false
                let fullscreen = (attribute("AXFullScreen", of: element) as? Bool) ?? false
                found.append(WindowInfo(id: id, pid: app.processIdentifier, appName: app.name, bundleID: app.bundleID, title: title, frame: rect, isMinimized: minimized, isOnScreen: (record?[kCGWindowIsOnscreen as String] as? Bool) ?? false, isFullscreen: fullscreen, processStartedAt: app.processStartedAt))
                nextElements[id] = element
                // Positive answers are cached; negatives are re-checked because a sheet or
                // dialog can disable a window's zoom button temporarily.
                if input.knownResizable.contains(id) || isResizable(element) { resizable.insert(id) }
                if record?[kCGWindowIsOnscreen as String] as? Bool == true {
                    if let nativeTabs = hasNativeTabs(element) {
                        if nativeTabs { nativeTabbedHosts.insert(id) }
                    } else {
                        // Optional native-tab metadata must not suppress window liveness.
                        // The host can preserve only geometrically matching aside candidates.
                        nativeTabVerdictUnknownHosts.insert(id)
                    }
                }
                if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, element) { focusedWindowID = id }
            }
        }
        return CensusResult(
            windows: found.sorted { ($0.appName, $0.title, $0.id) < ($1.appName, $1.title, $1.id) },
            elements: nextElements, focusedWindowID: focusedWindowID, zOrder: zOrder,
            unavailablePIDs: censusUnavailablePIDs, resizable: resizable, missionControlActive: missionControlActive, nativeTabbedHosts: nativeTabbedHosts, nativeTabVerdictUnknownHosts: nativeTabVerdictUnknownHosts)
    }
    /// A window can't be grouped if it can't take the group's size: its size isn't settable,
    /// or its zoom (green) button is disabled, as in System Settings and most fixed-size panels.
    nonisolated private static func isResizable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success, !settable.boolValue { return false }
        if let zoom = attribute(kAXZoomButtonAttribute, of: element), CFGetTypeID(zoom) == AXUIElementGetTypeID(),
           let enabled = attribute(kAXEnabledAttribute, of: unsafeBitCast(zoom, to: AXUIElement.self)) as? Bool, !enabled { return false }
        return true
    }
    /// Checks only immediate AXTabGroup children and their radio buttons.
    /// nil denotes unavailable or truncated evidence, never a confirmed negative.
    nonisolated private static func hasNativeTabs(_ window: AXUIElement) -> Bool? {
        func children(_ element: AXUIElement) -> (items: [AXUIElement], truncated: Bool)? {
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else { return nil }
            if count == 0 { return ([], false) }
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(count, 20), &values) == .success,
                  let items = values as? [AXUIElement] else { return nil }
            return (items, count > 20)
        }
        guard let outer = children(window) else { return nil }
        var unknown = outer.truncated
        for child in outer.items {
            guard let role = attribute(kAXRoleAttribute, of: child) as? String else { unknown = true; continue }
            guard role == kAXTabGroupRole else { continue }
            guard let inner = children(child) else { unknown = true; continue }
            unknown = unknown || inner.truncated
            var radioCount = 0
            for tab in inner.items {
                guard let tabRole = attribute(kAXRoleAttribute, of: tab) as? String else { unknown = true; continue }
                if tabRole == kAXRadioButtonRole { radioCount += 1 }
                if radioCount >= 2 { return true }
            }
        }
        return unknown ? nil : false
    }
    private func checkedElement(_ id: UInt32) -> AXUIElement? {
        guard accessibilityGranted else { lastError = "Accessibility permission has been revoked."; return nil }
        guard let element = elements[id] else { lastError = "The window is no longer available."; return nil }
        return element
    }
    @discardableResult private func check(_ result: AXError, action: String) -> Bool {
        guard result == .success else { lastError = "\(action) failed (Accessibility error \(result.rawValue))."; return false }
        return true
    }
    func focus(_ id: UInt32) {
        guard let element = checkedElement(id) else { return }
        lastError = nil
        if windows.first(where: { $0.id == id })?.isMinimized == true {
            _ = check(AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse), action: "Restore window")
        }
        if let info = windows.first(where: { $0.id == id }) { NSRunningApplication(processIdentifier: info.pid)?.activate(options: []) }
        _ = check(AXUIElementPerformAction(element, kAXRaiseAction as CFString), action: "Focus window")
    }
    func setFrame(_ frame: CGRect, for id: UInt32) {
        guard frame.width > 0, frame.height > 0, frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              let element = checkedElement(id) else { return }
        lastError = nil
        var position = frame.origin, size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        _ = check(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue), action: "Resize window")
        _ = check(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue), action: "Move window")
    }
    /// Reads one window's current frame synchronously through Accessibility.
    func liveFrame(_ id: UInt32) -> CGRect? {
        guard accessibilityGranted, let element = elements[id] else { return nil }
        // Called on the main thread: never wait long on a busy app.
        AXUIElementSetMessagingTimeout(element, 0.15)
        return Self.frame(of: element)
    }
    /// The window server's frame for a window (top-left global coordinates, like AX).
    /// Unlike an AX read this never waits on the owning app, so it is cheap enough to
    /// call every display frame while a window is being dragged or resized.
    nonisolated static func serverFrame(_ id: UInt32) -> CGRect? {
        if let bounds = SkyLight.shared.bounds(id) { return bounds }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let info = list.first, let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
    private let writer = FrameWriter()
    /// Non-blocking frame change. Writes run on a background queue and coalesce per window,
    /// so a slow app never stalls the UI and only the latest frame is applied.
    /// `priority` bypasses the per-app queue for the window the user is looking at.
    func setFrameAsync(_ frame: CGRect, for id: UInt32, priority: Bool = false) {
        guard frame.width > 0, frame.height > 0, frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              let element = checkedElement(id) else { return }
        let pid = windows.first(where: { $0.id == id })?.pid ?? 0
        writer.submit(id: id, pid: pid, element: element, frame: frame, priority: priority)
    }
    /// Current front-to-back order of on-screen windows, straight from the window server.
    /// The census copy can be 350 ms old, which is wrong right after a click raises a window.
    nonisolated static func liveZOrder() -> [UInt32] {
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return records.compactMap { record in
            guard (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }
    func close(_ id: UInt32) {
        guard let element = checkedElement(id) else { return }
        lastError = nil
        guard let button = Self.attribute(kAXCloseButtonAttribute, of: element), CFGetTypeID(button) == AXUIElementGetTypeID() else { lastError = "This window does not expose a close button."; return }
        _ = check(AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString), action: "Close window")
    }

    func thumbnail(_ id: UInt32) async -> NSImage? {
        // Preflight prevents this read operation from prompting for Screen Recording access.
        guard CGPreflightScreenCaptureAccess() else { lastError = "Screen Recording permission is required for previews."; return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == id }) else { lastError = "The window is unavailable for preview."; return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            // Sharp on Retina at the size the search preview shows it (about 500 pt wide).
            let width = 1200
            configuration.width = width
            configuration.height = min(2400, max(1, Int(CGFloat(width) * window.frame.height / max(1, window.frame.width))))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } catch { lastError = "Preview failed: \(error.localizedDescription)"; return nil }
    }
    func appIcon(_ id: UInt32) -> NSImage? {
        guard let info = windows.first(where: { $0.id == id }) else { return nil }
        return NSRunningApplication(processIdentifier: info.pid)?.icon
    }
}
