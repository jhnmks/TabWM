import AppKit
import CoreGraphics
import Darwin

/// Private SkyLight (WindowServer) entry points, resolved at runtime: window events and
/// window bounds. None of them needs System Integrity Protection disabled. Every entry point
/// is optional: if a future macOS renames or removes one, callers fall back to the public
/// CoreGraphics/AppKit path.
final class SkyLight: @unchecked Sendable {
    static let shared = SkyLight()

    /// Window-server notification codes.
    enum Event: UInt32 {
        case windowDestroyed = 804, windowMoved = 806, windowResized = 807, windowReordered = 808
        case frontAppChanged = 1508
    }

    typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, Int32) -> Void
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias RegisterNotifyProc = @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> CGError
    private typealias RequestNotificationsForWindows = @convention(c) (Int32, UnsafePointer<UInt32>?, Int32) -> CGError
    private typealias GetWindowBounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    let connection: Int32
    private let registerNotifyProc: RegisterNotifyProc?
    private let requestNotificationsForWindows: RequestNotificationsForWindows?
    private let getWindowBounds: GetWindowBounds?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces?
    private let copySpacesForWindows: CopySpacesForWindows?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func load<T>(_ name: String, _: T.Type) -> T? {
            guard let handle, let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        connection = load("SLSMainConnectionID", MainConnectionID.self)?() ?? 0
        registerNotifyProc = load("SLSRegisterNotifyProc", RegisterNotifyProc.self)
        requestNotificationsForWindows = load("SLSRequestNotificationsForWindows", RequestNotificationsForWindows.self)
        getWindowBounds = load("SLSGetWindowBounds", GetWindowBounds.self)
        copyManagedDisplaySpaces = load("SLSCopyManagedDisplaySpaces", CopyManagedDisplaySpaces.self)
        copySpacesForWindows = load("SLSCopySpacesForWindows", CopySpacesForWindows.self)
    }

    /// Mission Control's desktop number for each user Space ("Desktop 1", "Desktop 2", …),
    /// counted across displays in order, as Mission Control does. Full-screen app Spaces have
    /// no number.
    func desktopNumbers() -> [UInt64: Int] {
        guard connection != 0, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var numbers: [UInt64: Int] = [:], next = 1
        for display in displays {
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                // Type 0 is a normal desktop; 4 is a full-screen app.
                guard (space["type"] as? NSNumber)?.intValue == 0, let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { continue }
                numbers[id] = next; next += 1
            }
        }
        return numbers
    }
    /// The Space a window is on, or nil if the window server doesn't say (some apps' windows
    /// report none while hidden).
    func space(of window: UInt32) -> UInt64? {
        guard connection != 0, let copySpacesForWindows,
              let spaces = copySpacesForWindows(connection, 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return spaces.first?.uint64Value
    }

    var notificationsAvailable: Bool { connection != 0 && registerNotifyProc != nil && requestNotificationsForWindows != nil }

    /// The window's frame from the window server, in top-left global coordinates (like
    /// Accessibility). Never waits on the owning app, so it's cheap at display rate.
    func bounds(_ id: UInt32) -> CGRect? {
        guard connection != 0, let getWindowBounds else { return nil }
        var rect = CGRect.zero
        guard getWindowBounds(connection, id, &rect) == .success, rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    func register(_ event: Event, context: UnsafeMutableRawPointer?, proc: NotifyProc) -> Bool {
        guard let registerNotifyProc else { return false }
        return registerNotifyProc(proc, event.rawValue, context) == .success
    }
    /// Replaces the set of windows whose move/resize/reorder/destroy events we receive.
    func requestNotifications(for ids: [UInt32]) -> Bool {
        guard connection != 0, let requestNotificationsForWindows else { return false }
        return ids.withUnsafeBufferPointer { requestNotificationsForWindows(connection, $0.baseAddress, Int32($0.count)) } == .success
    }
}

/// Window-server move/resize/reorder/destroy notifications for the windows in groups.
/// Replaces polling: the frame now reacts to each window change as it happens.
@MainActor
final class WindowEvents {
    var onEvent: ((SkyLight.Event, UInt32) -> Void)?
    private(set) var active = false
    private var watched: [UInt32] = []

    func start() {
        let skyLight = SkyLight.shared
        guard !active, skyLight.notificationsAvailable else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var ok = true
        for event in [SkyLight.Event.windowMoved, .windowResized, .windowReordered, .windowDestroyed, .frontAppChanged] {
            ok = skyLight.register(event, context: context, proc: skyLightNotifyProc) && ok
        }
        active = ok
        if active, !watched.isEmpty { _ = skyLight.requestNotifications(for: watched) }
    }
    /// Call whenever group membership changes; the window server keeps one list per connection.
    func watch(_ ids: Set<UInt32>) {
        let sorted = ids.sorted()
        guard sorted != watched else { return }
        watched = sorted
        if active { _ = SkyLight.shared.requestNotifications(for: sorted) }
    }
    nonisolated func deliver(_ raw: UInt32, _ windowID: UInt32) {
        guard let event = SkyLight.Event(rawValue: raw) else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.onEvent?(event, windowID) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onEvent?(event, windowID) } }
        }
    }
}

/// C callback for SLSRegisterNotifyProc. For window events the payload starts with the window ID.
private let skyLightNotifyProc: SkyLight.NotifyProc = { event, data, length, context, _ in
    guard let context else { return }
    let windowID = (data != nil && length >= 4) ? data!.loadUnaligned(as: UInt32.self) : 0
    Unmanaged<WindowEvents>.fromOpaque(context).takeUnretainedValue().deliver(event, windowID)
}
