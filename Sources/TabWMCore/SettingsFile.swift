import Foundation

/// TabWM's settings file (`~/.config/TabWM/settings.toml`), also used for export and import.
///
/// It holds only the choices the Settings window offers, in TOML, grouped like the Settings
/// pages. Options that only apply to one frame style are written only for that style. Keys
/// are named in plain words ("globe", "right-option", "G", "left"); shortcuts that use the
/// leader start with `leader`, so the leader key is chosen once, at the top, and every
/// shortcut follows it:
///
///     leader = "globe"
///
///     [shortcuts]
///     group-all = "leader+G"
///     search    = "cmd+opt+S"     # a combo of its own, without the leader
///     ungroup   = "off"
///
/// Reading is forgiving: unknown keys are ignored, missing ones keep their defaults, and
/// invalid values are corrected the same way as in the Settings window.
public enum SettingsFile {
    public enum FileError: LocalizedError {
        case syntax(line: Int, message: String)
        case notASettingsFile
        public var errorDescription: String? {
            switch self {
            case .syntax(let line, let message): return "Line \(line): \(message)"
            case .notASettingsFile: return "This isn't a TabWM settings file."
            }
        }
    }

    // MARK: Names used in the file

    static let leaders = ["globe": "globe", "rightCommand": "right-cmd", "rightOption": "right-opt", "rightControl": "right-ctrl",
                          "controlOption": "ctrl+opt", "controlOptionCommand": "ctrl+opt+cmd", "hyper": "hyper", "off": "off"]
    static let groupingKeys = ["leader": "leader", "shift": "shift", "control": "ctrl", "option": "opt", "command": "cmd", "none": "none"]
    static let newWindows = ["focused": "join-current-group", "off": "stay-alone"]
    static let policies = ["suspend": "keep-tab", "detach": "remove"]
    static let styles = ["glass": "glass", "catppuccin": "color"]
    static let actions: [(ShortcutAction, String)] = [
        (.groupAll, "group-all"), (.addTab, "add-windows"), (.ungroup, "ungroup"),
        (.search, "search"), (.previousTab, "previous-tab"), (.nextTab, "next-tab"),
    ]
    /// Key codes for names (U.S. layout positions; shortcuts match the physical key).
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
            45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 48: "tab", 49: "space", 51: "delete",
            53: "escape", 117: "forward-delete", 115: "home", 119: "end", 116: "page-up", 121: "page-down",
            27: "minus", 24: "equal", 33: "left-bracket", 30: "right-bracket", 41: "semicolon", 39: "quote",
            43: "comma", 47: "period", 44: "slash", 42: "backslash", 50: "grave",
        ]
        for (i, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { names[UInt32(code)] = "F\(i + 1)" }
        return names
    }()
    static let modifierNames: [(UInt32, String)] = [(KeyModifier.control, "ctrl"), (KeyModifier.option, "opt"), (KeyModifier.shift, "shift"), (KeyModifier.command, "cmd")]
    static let modifierAliases: [String: UInt32] = [
        "ctrl": KeyModifier.control, "control": KeyModifier.control, "opt": KeyModifier.option, "option": KeyModifier.option,
        "alt": KeyModifier.option, "shift": KeyModifier.shift, "cmd": KeyModifier.command, "command": KeyModifier.command,
    ]

    /// "leader+G", "leader+shift+right", "cmd+opt+S", or "off".
    public static func describe(_ b: ShortcutBinding) -> String {
        guard b.enabled else { return "off" }
        var parts = b.usesLeader ? ["leader"] : []
        parts += modifierNames.filter { b.modifiers & $0.0 != 0 }.map(\.1)
        parts.append(keyNames[b.keyCode] ?? "key\(b.keyCode)")
        return parts.joined(separator: "+")
    }
    static func binding(_ text: String, current: ShortcutBinding) -> ShortcutBinding? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.lowercased() == "off" { var b = current; b.enabled = false; return b }
        var parts = value.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.popLast(), !keyName.isEmpty else { return nil }
        let code: UInt32? = keyNames.first { $0.value.lowercased() == keyName.lowercased() }?.key
            ?? (keyName.lowercased().hasPrefix("key") ? UInt32(keyName.dropFirst(3)) : nil)
        guard let code else { return nil }
        var binding = ShortcutBinding(keyCode: code, usesLeader: false)
        for part in parts {
            if part.lowercased() == "leader" { binding.usesLeader = true; continue }
            guard let mask = modifierAliases[part.lowercased()] else { return nil }
            binding.modifiers |= mask
        }
        return binding
    }

    // MARK: Writing

    /// Readable names for the built-in ignored apps, written as comments next to them.
    static let appNames = [
        "com.apple.Spotlight": "Spotlight", "com.apple.WindowManager": "Stage Manager",
        "com.apple.controlcenter": "Control Center", "com.apple.dock": "Dock",
        "com.apple.notificationcenterui": "Notification Center", "com.apple.systempreferences": "System Settings",
        "com.apple.systemuiserver": "Menu bar extras", "com.apple.loginwindow": "Login window",
        "com.apple.SecurityAgent": "Password prompts", "com.apple.UserNotificationCenter": "System alerts",
        "com.apple.screencaptureui": "Screenshot", "com.apple.ScreenSaver.Engine": "Screen saver",
        "com.apple.PIPAgent": "Picture in Picture", "com.apple.Siri": "Siri",
        "com.apple.CharacterPaletteIM": "Emoji & Symbols", "com.apple.TextInputMenuAgent": "Input menu",
        "com.apple.AccessibilityUIServer": "Accessibility", "com.apple.coreservices.uiagent": "System dialogs",
        "com.apple.ScreenContinuity": "iPhone Mirroring", "com.raycast.macos": "Raycast",
        "com.runningwithcrayons.Alfred": "Alfred",
    ]
    static let appGroups: [(String, [String])] = [
        ("macOS", ["com.apple.Spotlight", "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.dock",
                   "com.apple.notificationcenterui", "com.apple.systempreferences", "com.apple.systemuiserver"]),
        ("System prompts and overlays", ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
                                         "com.apple.coreservices.uiagent", "com.apple.screencaptureui", "com.apple.ScreenSaver.Engine",
                                         "com.apple.PIPAgent", "com.apple.Siri", "com.apple.ScreenContinuity"]),
        ("Input and accessibility", ["com.apple.CharacterPaletteIM", "com.apple.TextInputMenuAgent", "com.apple.AccessibilityUIServer"]),
        ("Launchers", ["com.raycast.macos", "com.runningwithcrayons.Alfred"]),
    ]

    /// Writes the file: a header box per section, related settings in small blocks separated
    /// by blank lines, values lined up in one column, and the allowed values as a comment at
    /// the end of each line.
    public static func text(_ s: AppSettings) -> String {
        func q(_ v: String) -> String { "\"\(v)\"" }
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%g", v) }
        /// A setting: what it does (a comment above it, optional), its value, and what it
        /// accepts (a comment at the end of the line, always).
        struct Row { var about = ""; var key: String; var value: String; var options: String }
        /// A block of settings with their `=`, values, and option comments lined up.
        func block(_ rows: [Row]) -> [String] {
            let keyWidth = rows.map(\.key.count).max() ?? 0
            let valueWidth = rows.map(\.value.count).max() ?? 0
            return rows.flatMap { row -> [String] in
                let line = row.key.padding(toLength: keyWidth, withPad: " ", startingAt: 0) + " = "
                    + row.value.padding(toLength: valueWidth, withPad: " ", startingAt: 0) + "   # " + row.options
                return (row.about.isEmpty ? [] : ["# " + row.about]) + [line]
            }
        }
        func section(_ name: String?, _ title: String, _ about: [String] = []) -> [String] {
            let rule = "# " + String(repeating: "─", count: 78)
            var lines = ["", "", rule, "#  \(title)"]
            lines += about.map { "#  \($0)" }
            lines += [rule, ""]
            if let name { lines += ["[\(name)]", ""] }
            return lines
        }
        func choices(_ values: [String]) -> String { values.joined(separator: " | ") }
        let onOff = choices(["true", "false"])

        var lines = [
            "# ╭──────────────────────────────────────────────────────────────────────────────╮",
            "# │  TabWM settings                                                              │",
            "# │                                                                              │",
            "# │  Save this file and TabWM applies the changes right away.                    │",
            "# │  The comment after each setting lists what you can put there.                │",
            "# │  Leave a setting out to use its default. Settings → General → Restore        │",
            "# │  Defaults puts everything back.                                              │",
            "# ╰──────────────────────────────────────────────────────────────────────────────╯",
        ]

        // Leader
        lines += section(nil, "Leader key", [
            "Hold it, then press a shortcut key. Every \"leader+…\" shortcut follows it,",
            "so change it here once.",
        ])
        lines += block([
            Row(about: "globe = the fn/globe key · right-… = the right-hand modifier · ctrl+opt… = held together",
                key: "leader", value: q(leaders[s.leaderKey] ?? "globe"),
                options: choices(["globe", "right-cmd", "right-opt", "right-ctrl", "ctrl+opt", "ctrl+opt+cmd", "hyper", "off"])),
            Row(about: "Also allow tapping the leader, then pressing the key within a second",
                key: "tap-leader", value: "\(s.leaderSequence)", options: onOff),
        ])

        // Shortcuts
        lines += section("shortcuts", "Shortcuts", [
            "Write a shortcut as one of:",
            "  \"leader+KEY\"          the leader key, then KEY            e.g. \"leader+G\"",
            "  \"leader+shift+KEY\"    the leader key, then ⇧ and KEY      e.g. \"leader+shift+right\"",
            "  \"MODIFIERS+KEY\"       a combo of its own, no leader       e.g. \"cmd+opt+S\"",
            "  \"off\"                 no shortcut",
            "",
            "MODIFIERS: ctrl, opt, shift, cmd (join with +)",
            "KEY:       A–Z · 0–9 · F1–F12 · left, right, up, down · return, tab, space,",
            "           escape, delete, forward-delete, home, end, page-up, page-down ·",
            "           minus, equal, left-bracket, right-bracket, semicolon, quote,",
            "           comma, period, slash, backslash, grave",
        ])
        let shortcutOptions = "\"leader+KEY\" | \"MODIFIERS+KEY\" | \"off\""
        func shortcutRow(_ action: ShortcutAction, _ about: String) -> Row {
            Row(about: about, key: actions.first { $0.0 == action }!.1, value: q(describe(s.binding(for: action))), options: shortcutOptions)
        }
        lines.append("# ── Groups")
        lines += block([
            shortcutRow(.groupAll, "Put every window on this desktop into one group"),
            shortcutRow(.addTab, "Add ungrouped windows to the current group"),
            shortcutRow(.ungroup, "Split up the current group"),
        ])
        lines += ["", "# ── Tabs"]
        lines += block([
            shortcutRow(.previousTab, "Show the tab to the left"),
            shortcutRow(.nextTab, "Show the tab to the right"),
            shortcutRow(.search, "Find any tab by name"),
        ])

        // Grouping
        lines += section("grouping", "Grouping")
        lines.append("# ── Making groups")
        lines += block([
            Row(about: "A window you open joins the group you were working in, or stays on its own",
                key: "new-windows", value: q(newWindows[s.newWindowPolicy] ?? "join-current-group"),
                options: choices(["join-current-group", "stay-alone"])),
            Row(about: "Key to hold while dragging a window onto another to group them",
                key: "drag-key", value: q(groupingKeys[s.modifier] ?? "leader"),
                options: choices(["leader", "shift", "ctrl", "opt", "cmd", "none"])),
            Row(about: "Seconds before the \"Release to group\" highlight appears",
                key: "drag-delay", value: n(s.holdDelay), options: "0 – 1.5"),
        ])
        lines += ["", "# ── When a window leaves the screen", "# keep-tab = stays in the group, paused · remove = leaves the group"]
        lines += block([
            Row(key: "when-full-screen", value: q(policies[s.fullscreenPolicy] ?? "keep-tab"), options: choices(["keep-tab", "remove"])),
            Row(key: "when-moved-to-another-desktop", value: q(policies[s.offSpacePolicy] ?? "keep-tab"), options: choices(["keep-tab", "remove"])),
        ])
        lines += ["", "# ── Tab search"]
        lines += block([
            Row(about: "The search button in tab strips and the search shortcut",
                key: "tab-search", value: "\(s.searchEnabled)", options: onOff),
        ])
        // Ignored apps, grouped by kind, each with its name.
        lines += ["", "# ── Ignored apps",
                  "# Windows of these apps are never grouped. Add any app by its bundle ID, in quotes,",
                  "# followed by a comma. Find an app's ID with: osascript -e 'id of app \"Safari\"'",
                  "ignored-apps = ["]
        let ignored = s.excludedBundleIDs
        let idWidth = (ignored.map(\.count).max() ?? 0) + 3
        func appLine(_ id: String) -> String {
            guard let name = appNames[id] else { return "  " + q(id) + "," }
            return "  " + (q(id) + ",").padding(toLength: idWidth, withPad: " ", startingAt: 0) + " # " + name
        }
        var listed = Set<String>()
        for (title, ids) in appGroups {
            let present = ids.filter(ignored.contains)
            guard !present.isEmpty else { continue }
            if !listed.isEmpty { lines.append("") }
            lines.append("  # \(title)")
            lines += present.map(appLine)
            listed.formUnion(present)
        }
        let own = ignored.filter { !listed.contains($0) }
        if !listed.isEmpty { lines.append("") }
        lines.append("  # Your apps")
        lines += own.isEmpty ? ["  # \"com.example.app\","] : own.map(appLine)
        lines.append("]")

        // Appearance
        lines += section("appearance", "Appearance")
        lines.append("# ── Frame style")
        var style = [
            Row(about: "glass = see-through Liquid Glass · color = solid Catppuccin colors",
                key: "style", value: q(styles[s.frameStyle] ?? "glass"), options: choices(["glass", "color"])),
        ]
        if s.frameStyle == "catppuccin" {
            style.append(Row(about: "Border color (Latte shade in light mode, Mocha shade in dark mode)",
                             key: "color", value: q(s.frameColor), options: "see the list below"))
        }
        style += [
            Row(about: "Light or dark tab strips; system follows macOS",
                key: "theme", value: q(s.appearance), options: choices(["system", "light", "dark"])),
            Row(about: "How solid the strip and border are (1 = fully solid)",
                key: "opacity", value: n(s.tabBarOpacity), options: "0.3 – 1"),
        ]
        lines += block(style)
        if s.frameStyle == "catppuccin" {
            lines += ["# color: " + AppSettings.frameColors.prefix(7).joined(separator: " | "),
                      "#        " + AppSettings.frameColors.dropFirst(7).joined(separator: " | ")]
        }
        lines += ["", "# ── Size, in points"]
        lines += block([
            Row(about: "Height of the bar with the tabs", key: "tab-strip-height", value: n(s.tabBarHeight), options: "24 – 42"),
            Row(about: "Width of the shell around the tabs and window; 0 hides it", key: "border-width", value: n(s.frameThickness), options: "0 – 10"),
        ])
        lines += ["", "# ── Tabs"]
        lines += block([
            Row(about: "Show app badges (like unread mail) on tabs",
                key: "notification-badges", value: "\(s.showBadges)", options: onOff),
        ])

        // General
        lines += section("general", "General")
        lines += block([
            Row(about: "Open TabWM when you log in", key: "launch-at-login", value: "\(s.launchAtLogin)", options: onOff),
        ])

        return lines.joined(separator: "\n") + "\n"
    }
    public static func data(_ settings: AppSettings) -> Data { Data(text(settings).utf8) }
    public static func save(_ settings: AppSettings, to url: URL) throws { try data(settings).write(to: url, options: .atomic) }

    // MARK: Reading

    public static func settings(from data: Data) throws -> AppSettings {
        guard let text = String(data: data, encoding: .utf8) else { throw FileError.notASettingsFile }
        return try settings(from: text)
    }
    public static func load(from url: URL) throws -> AppSettings { try settings(from: Data(contentsOf: url)) }

    public static func settings(from text: String) throws -> AppSettings {
        let table = try TOML.parse(text)
        var s = AppSettings()
        func string(_ key: String) -> String? { table[key] as? String }
        func bool(_ key: String) -> Bool? { table[key] as? Bool }
        func number(_ key: String) -> Double? { table[key] as? Double }
        func pick(_ key: String, _ names: [String: String]) -> String? {
            guard let value = string(key)?.lowercased() else { return nil }
            return names.first { $0.value == value }?.key ?? "invalid"
        }
        if let v = pick("leader", leaders) { s.leaderKey = v }
        if let v = bool("tap-leader") { s.leaderSequence = v }
        if let v = bool("general.launch-at-login") { s.launchAtLogin = v }
        if let v = pick("grouping.new-windows", newWindows) { s.newWindowPolicy = v }
        if let v = pick("grouping.drag-key", groupingKeys) { s.modifier = v }
        if let v = number("grouping.drag-delay") { s.holdDelay = v }
        if let v = pick("grouping.when-full-screen", policies) { s.fullscreenPolicy = v }
        if let v = pick("grouping.when-moved-to-another-desktop", policies) { s.offSpacePolicy = v }
        if let v = bool("grouping.tab-search") { s.searchEnabled = v }
        if let v = table["grouping.ignored-apps"] as? [String] { s.excludedBundleIDs = v }
        if let v = pick("appearance.style", styles) { s.frameStyle = v }
        if let v = string("appearance.color") { s.frameColor = v.lowercased() }
        if let v = string("appearance.theme") { s.appearance = v.lowercased() }
        if let v = number("appearance.opacity") { s.tabBarOpacity = v }
        if let v = number("appearance.tab-strip-height") { s.tabBarHeight = v }
        if let v = number("appearance.border-width") { s.frameThickness = v }
        if let v = bool("appearance.notification-badges") { s.showBadges = v }
        for (action, name) in actions {
            guard let value = string("shortcuts.\(name)") else { continue }
            guard let binding = binding(value, current: s.binding(for: action)) else {
                throw FileError.syntax(line: TOML.line(of: "\(name)", in: text), message: "“\(value)” isn't a key TabWM knows for \(name).")
            }
            s.setBinding(binding, for: action)
        }
        s.normalize()
        return s
    }
}

/// The part of TOML a settings file needs: comments, `[section]` headers, and `key = value`
/// with strings, numbers, booleans, and (multi-line) string arrays. Keys come back as
/// "section.key".
enum TOML {
    static func parse(_ text: String) throws -> [String: Any] {
        var table: [String: Any] = [:]
        var section = ""
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let number = i + 1
            var line = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw SettingsFile.FileError.syntax(line: number, message: "A section header needs a closing ].") }
                section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw SettingsFile.FileError.syntax(line: number, message: "Expected key = value.") }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // Arrays may span lines.
            if value.hasPrefix("[") {
                while !value.hasSuffix("]") && i < lines.count {
                    line = stripComment(lines[i]).trimmingCharacters(in: .whitespaces); i += 1
                    value += line
                }
            }
            table[section.isEmpty ? key : "\(section).\(key)"] = try parseValue(value, line: number)
        }
        return table
    }
    static func parseValue(_ raw: String, line: Int) throws -> Any {
        if raw == "true" { return true }
        if raw == "false" { return false }
        if raw.hasPrefix("\"") {
            guard raw.count >= 2, raw.hasSuffix("\"") else { throw SettingsFile.FileError.syntax(line: line, message: "A text value needs closing quotes.") }
            return String(raw.dropFirst().dropLast())
        }
        if raw.hasPrefix("[") {
            guard raw.hasSuffix("]") else { throw SettingsFile.FileError.syntax(line: line, message: "A list needs a closing ].") }
            return try raw.dropFirst().dropLast().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { item -> String in
                    guard let text = try parseValue(item, line: line) as? String else { throw SettingsFile.FileError.syntax(line: line, message: "Lists hold text in quotes.") }
                    return text
                }
        }
        if let number = Double(raw.replacingOccurrences(of: "_", with: "")) { return number }
        throw SettingsFile.FileError.syntax(line: line, message: "“\(raw)” isn't a value TabWM understands. Text needs quotes.")
    }
    /// Drops a `#` comment, keeping `#` inside quotes.
    static func stripComment(_ line: String) -> String {
        var quoted = false
        for (index, char) in zip(line.indices, line) {
            if char == "\"" { quoted.toggle() }
            if char == "#" && !quoted { return String(line[..<index]) }
        }
        return line
    }
    static func line(of key: String, in text: String) -> Int {
        (text.components(separatedBy: .newlines).firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key) } ?? 0) + 1
    }
}
