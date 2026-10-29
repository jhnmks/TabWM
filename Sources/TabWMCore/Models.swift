import Foundation
import CoreGraphics

public struct WindowInfo: Identifiable, Codable, Equatable {
    public var id: UInt32
    public var pid: Int32
    public var appName: String
    public var bundleID: String
    /// Runtime identity guard when the OS reuses a process ID. Optional for old sessions.
    public var processStartedAt: TimeInterval?
    public var title: String
    public var frame: CGRect
    public var isMinimized: Bool
    public var isOnScreen: Bool
    public var isFullscreen: Bool
    public init(id: UInt32, pid: Int32, appName: String, bundleID: String, title: String, frame: CGRect, isMinimized: Bool = false, isOnScreen: Bool = true, isFullscreen: Bool = false, processStartedAt: TimeInterval? = nil) {
        self.id = id; self.pid = pid; self.appName = appName; self.bundleID = bundleID
        self.title = title; self.frame = frame; self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen; self.isFullscreen = isFullscreen
        self.processStartedAt = processStartedAt
    }
}

public struct WindowGroup: Identifiable, Codable, Equatable {
    public var id: UUID
    public var members: [UInt32]
    public var activeWindowID: UInt32
    public var frame: CGRect
    public var name: String?
    public var isLocked: Bool
    public var suspended: Set<UInt32>
    public var minimized: Set<UInt32>
    public var mru: [UInt32]
    public init(id: UUID = UUID(), members: [UInt32], activeWindowID: UInt32, frame: CGRect, name: String? = nil, isLocked: Bool = false, suspended: Set<UInt32> = [], minimized: Set<UInt32> = [], mru: [UInt32]? = nil) {
        self.id = id; self.members = members; self.activeWindowID = activeWindowID; self.frame = frame
        self.name = name; self.isLocked = isLocked
        self.suspended = suspended; self.minimized = minimized
        self.mru = mru ?? [activeWindowID] + members.filter { $0 != activeWindowID }
    }
    private enum CodingKeys: String, CodingKey {
        case id, members, activeWindowID, frame, name, isLocked, suspended, minimized, mru
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        members = try values.decode([UInt32].self, forKey: .members)
        activeWindowID = try values.decode(UInt32.self, forKey: .activeWindowID)
        frame = try values.decode(CGRect.self, forKey: .frame)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        isLocked = try values.decode(Bool.self, forKey: .isLocked)
        suspended = try values.decode(Set<UInt32>.self, forKey: .suspended)
        minimized = try values.decode(Set<UInt32>.self, forKey: .minimized)
        // Sessions saved before MRU support remain readable.
        let active = activeWindowID
        let initialMRU = [active] + members.filter { $0 != active }
        mru = try values.decodeIfPresent([UInt32].self, forKey: .mru) ?? initialMRU
    }
}

/// Carbon modifier masks, so the core can describe shortcuts without importing Carbon.
public enum KeyModifier {
    public static let command: UInt32 = 0x100, shift: UInt32 = 0x200, option: UInt32 = 0x800, control: UInt32 = 0x1000
    public static let all: UInt32 = 0x1f00
}

public enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    case groupAll, addTab, ungroup, search, previousTab, nextTab
    public var title: String {
        switch self {
        case .groupAll: return "Group all windows on this Space"
        case .addTab: return "Add windows to the current group"
        case .ungroup: return "Ungroup the current group"
        case .search: return "Search tabs"
        case .previousTab: return "Previous tab"
        case .nextTab: return "Next tab"
        }
    }
}

/// A global shortcut. With `usesLeader` it is the shared leader plus `keyCode` (and an
/// optional extra Shift in `modifiers`); otherwise it is a standalone combo in `modifiers`.
public struct ShortcutBinding: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var usesLeader: Bool
    public var enabled: Bool
    public init(keyCode: UInt32, modifiers: UInt32 = 0, usesLeader: Bool = true, enabled: Bool = true) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.usesLeader = usesLeader; self.enabled = enabled
    }
}

public struct AppSettings: Codable, Equatable {
    /// Key held while dragging a window onto another to group them. "leader" follows
    /// `leaderKey`; otherwise "shift", "control", "option", "command", or "none".
    public var modifier = "leader"
    /// Bumped when a default changes in a way old settings files should pick up.
    public var settingsRevision = 3
    public var holdDelay = 0.0
    public var tabBarHeight = 29.0
    /// Width of the outer shell around a group: above the tab strip and around the window.
    public var frameThickness = 2.0
    public var tabBarOpacity = 1.0
    /// How the tab strip and border are drawn: "glass" (Liquid Glass) or "catppuccin" (solid
    /// Catppuccin colors: Latte in light mode, Mocha in dark mode).
    public var frameStyle = "glass"
    /// Catppuccin accent used for the border with the "catppuccin" style, e.g. "mauve".
    public var frameColor = "mauve"
    public var appearance = "system"
    public var showBadges = true
    public var searchEnabled = true
    public var excludedBundleIDs: [String] = AppSettings.defaultExcludedBundleIDs
    /// System UI, overlays, and launchers whose windows should never become tabs.
    public static let defaultExcludedBundleIDs = [
        // System UI
        "com.apple.Spotlight", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.dock",
        "com.apple.notificationcenterui", "com.apple.systempreferences", "com.apple.systemuiserver",
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
        "com.apple.screencaptureui", "com.apple.ScreenSaver.Engine", "com.apple.PIPAgent",
        "com.apple.Siri", "com.apple.CharacterPaletteIM", "com.apple.TextInputMenuAgent",
        "com.apple.AccessibilityUIServer", "com.apple.coreservices.uiagent", "com.apple.ScreenContinuity",
        // Launchers and overlays
        "com.raycast.macos", "com.runningwithcrayons.Alfred",
    ]
    /// What happens to a newly opened window: "focused" (join the group you were working in)
    /// or "off" (stay ungrouped).
    public var newWindowPolicy = "focused"
    public var fullscreenPolicy = "suspend"
    /// Detaching on Space changes misfired while macOS animates the switch, so the default
    /// keeps such windows as suspended tabs.
    public var offSpacePolicy = "suspend"
    public var launchAtLogin = false
    /// The key every leader shortcut inherits. Solo keys ("globe", "rightCommand",
    /// "rightOption", "rightControl") are held or tapped; chords ("controlOption",
    /// "controlOptionCommand", "hyper") are pressed together with the action key; "off".
    public var leaderKey = "globe"
    /// For solo leaders: besides holding the leader, allow tapping it and then pressing a key.
    public var leaderSequence = true
    /// Keyed by `ShortcutAction.rawValue`; a missing entry means the default binding.
    public var shortcuts: [String: ShortcutBinding] = [:]
    public init() {}
    // Defaults: leader + G, T, U, S, ←, →.
    public static let defaultShortcuts: [ShortcutAction: ShortcutBinding] = [
        .groupAll: ShortcutBinding(keyCode: 5), .addTab: ShortcutBinding(keyCode: 17), .ungroup: ShortcutBinding(keyCode: 32), .search: ShortcutBinding(keyCode: 1),
        .previousTab: ShortcutBinding(keyCode: 123), .nextTab: ShortcutBinding(keyCode: 124),
    ]
    /// Modifier masks for chord leaders; solo leaders and "off" have none.
    public static let leaderChords: [String: UInt32] = [
        "controlOption": KeyModifier.control | KeyModifier.option,
        "controlOptionCommand": KeyModifier.control | KeyModifier.option | KeyModifier.command,
        "hyper": KeyModifier.control | KeyModifier.option | KeyModifier.shift | KeyModifier.command,
    ]
    public func binding(for action: ShortcutAction) -> ShortcutBinding {
        shortcuts[action.rawValue] ?? Self.defaultShortcuts[action]!
    }
    public mutating func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        shortcuts[action.rawValue] = binding == Self.defaultShortcuts[action] ? nil : binding
    }
    private enum CodingKeys: String, CodingKey {
        case modifier, settingsRevision, holdDelay, tabBarHeight, frameThickness, tabBarOpacity, frameStyle, frameColor, appearance, showBadges, searchEnabled, excludedBundleIDs, newWindowPolicy, fullscreenPolicy, offSpacePolicy, launchAtLogin
        case leaderKey, leaderSequence, shortcuts
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modifier = try values.decodeIfPresent(String.self, forKey: .modifier) ?? modifier
        // Revision 1: the grouping key follows the leader. Files written before that saved
        // the old Shift default, so move them to the new default; explicit choices stay.
        let revision = try values.decodeIfPresent(Int.self, forKey: .settingsRevision) ?? 0
        if revision < 1 && modifier == "shift" { modifier = "leader" }
        settingsRevision = 3
        holdDelay = try values.decodeIfPresent(Double.self, forKey: .holdDelay) ?? holdDelay
        tabBarHeight = try values.decodeIfPresent(Double.self, forKey: .tabBarHeight) ?? tabBarHeight
        frameThickness = try values.decodeIfPresent(Double.self, forKey: .frameThickness) ?? frameThickness
        tabBarOpacity = try values.decodeIfPresent(Double.self, forKey: .tabBarOpacity) ?? tabBarOpacity
        frameStyle = try values.decodeIfPresent(String.self, forKey: .frameStyle) ?? frameStyle
        frameColor = try values.decodeIfPresent(String.self, forKey: .frameColor) ?? frameColor
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        showBadges = try values.decodeIfPresent(Bool.self, forKey: .showBadges) ?? showBadges
        searchEnabled = try values.decodeIfPresent(Bool.self, forKey: .searchEnabled) ?? searchEnabled
        excludedBundleIDs = try values.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? excludedBundleIDs
        // Revision 3: system apps are excluded by default; add them once to older files.
        // Apps the user removes afterwards stay removed.
        if revision < 3 {
            excludedBundleIDs = Self.defaultExcludedBundleIDs + excludedBundleIDs.filter { !Self.defaultExcludedBundleIDs.contains($0) }
        }
        newWindowPolicy = try values.decodeIfPresent(String.self, forKey: .newWindowPolicy) ?? newWindowPolicy
        fullscreenPolicy = try values.decodeIfPresent(String.self, forKey: .fullscreenPolicy) ?? fullscreenPolicy
        offSpacePolicy = try values.decodeIfPresent(String.self, forKey: .offSpacePolicy) ?? offSpacePolicy
        // Revision 2: the off-Space default became "suspend"; move files still on the old default.
        if revision < 2 && offSpacePolicy == "detach" { offSpacePolicy = "suspend" }
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        leaderKey = try values.decodeIfPresent(String.self, forKey: .leaderKey) ?? leaderKey
        leaderSequence = try values.decodeIfPresent(Bool.self, forKey: .leaderSequence) ?? leaderSequence
        // Older settings files used separate shortcut fields; those are dropped in favour of defaults.
        shortcuts = try values.decodeIfPresent([String: ShortcutBinding].self, forKey: .shortcuts) ?? shortcuts
    }
}
