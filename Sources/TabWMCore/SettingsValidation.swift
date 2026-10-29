import Foundation

extension AppSettings {
    /// Catppuccin accent names, in the palette's own order, plus "dark" (#1E1E2D in both themes).
    public static let frameColors = ["rosewater", "flamingo", "pink", "mauve", "red", "maroon", "peach", "yellow", "green", "teal", "sky", "sapphire", "blue", "lavender", "dark"]
    public static let leaderKeys = ["globe", "rightCommand", "rightOption", "rightControl", "controlOption", "controlOptionCommand", "hyper", "off"]
    public mutating func normalize() {
        let d = AppSettings()
        if !["leader", "none", "shift", "control", "option", "command"].contains(modifier) { modifier = "leader" }
        if !["suspend", "detach"].contains(fullscreenPolicy) { fullscreenPolicy = "suspend" }
        if !["off", "focused"].contains(newWindowPolicy) { newWindowPolicy = "focused" }
        if !["suspend", "detach"].contains(offSpacePolicy) { offSpacePolicy = "suspend" }
        if !["system", "light", "dark"].contains(appearance) { appearance = "system" }
        if !["glass", "catppuccin"].contains(frameStyle) { frameStyle = "glass" }
        if !Self.frameColors.contains(frameColor) { frameColor = d.frameColor }
        holdDelay = holdDelay.isFinite ? min(1.5, max(0, holdDelay)) : d.holdDelay
        tabBarHeight = tabBarHeight.isFinite ? min(42, max(24, tabBarHeight.rounded())) : d.tabBarHeight
        frameThickness = frameThickness.isFinite ? min(10, max(0, frameThickness.rounded())) : d.frameThickness
        tabBarOpacity = tabBarOpacity.isFinite ? min(1, max(0.3, tabBarOpacity)) : d.tabBarOpacity
        var seen = Set<String>()
        excludedBundleIDs = excludedBundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        if !Self.leaderKeys.contains(leaderKey) { leaderKey = "globe" }
        var cleaned: [String: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases {
            guard var binding = shortcuts[action.rawValue] else { continue }
            guard binding.keyCode <= 127 else { continue }   // invalid: fall back to the default
            binding.modifiers &= KeyModifier.all
            // Only Shift and Control may accompany a leader binding; the leader itself is the modifier.
            if binding.usesLeader { binding.modifiers &= KeyModifier.leaderExtras }
            // A standalone global combo needs Control, Option, or Command.
            else if binding.modifiers & (KeyModifier.control | KeyModifier.option | KeyModifier.command) == 0 { continue }
            if binding != Self.defaultShortcuts[action] { cleaned[action.rawValue] = binding }
        }
        shortcuts = cleaned
    }
}
