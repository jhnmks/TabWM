import AppKit
import SwiftUI
import CoreGraphics
import ServiceManagement
import TabWMCore

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State var category: String
    /// Offscreen rendering: draw only the page, without the split view.
    var pageOnly: Bool
    @State private var newExclusion = ""
    @State private var permissionTick = false
    // Explicit: the private state above makes the synthesized initializer private.
    init(controller: AppController, category: String = "General", pageOnly: Bool = false) {
        self.controller = controller
        _category = State(initialValue: category)
        self.pageOnly = pageOnly
    }
    let categories = ["General", "Grouping", "Appearance", "Shortcuts", "How to Use", "About"]
    static let icons = ["General": "gearshape", "Grouping": "rectangle.stack", "Appearance": "paintbrush", "Shortcuts": "keyboard", "How to Use": "questionmark.circle", "About": "info.circle"]
    static let subtitles = [
        "General": "Permissions TabWM needs, and how it starts.",
        "Grouping": "How windows join, leave, and behave inside a group.",
        "Appearance": "How the tab strip and the frame around a group look.",
        "Shortcuts": "Keyboard shortcuts for switching tabs and managing groups.",
        "How to Use": "A quick tour of everything TabWM can do.",
        "About": "Version and troubleshooting.",
    ]
    var body: some View {
        if pageOnly { page.background(.background) } else {
            NavigationSplitView {
                List(categories, id: \.self, selection: $category) { Label($0, systemImage: Self.icons[$0] ?? "gear").padding(.vertical, 3).tag($0) }
                    .navigationSplitViewColumnWidth(190)
            } detail: {
                ScrollView { page }
            }
            .onChange(of: controller.settings) { _, _ in controller.applySettings() }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in permissionTick.toggle() }
        }
    }
    var page: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(category).font(.largeTitle.bold())
                if let subtitle = Self.subtitles[category] { Text(subtitle).font(.title3).foregroundStyle(.secondary) }
            }
            switch category {
            case "General": general
            case "Grouping": grouping
            case "Appearance": appearance
            case "Shortcuts": shortcuts
            case "How to Use": tutorial
            default: about
            }
            if !controller.status.isEmpty { Text(controller.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = controller.system.lastError { Text(error).font(.callout).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 36).padding(.vertical, 32)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: General

    var general: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Permissions", symbol: "lock.shield",
                         note: "macOS asks before an app may control other windows. TabWM never sends anything anywhere; these permissions only let it work on your Mac.") {
                permissionRow(.accessibility, granted: controller.system.accessibilityGranted,
                              detail: "Required. Lets TabWM see your windows, put them into groups, switch between them, and close them when you click ×.")
                SettingsDivider()
                permissionRow(.inputMonitoring, granted: controller.shortcuts.isActive,
                              detail: "Required for keyboard shortcuts, such as switching tabs with the leader key and the arrow keys.")
                SettingsDivider()
                permissionRow(.screenRecording, granted: CGPreflightScreenCaptureAccess(), title: "Screen Recording",
                              detail: "Optional. Only used to show a small picture of the window you pick in tab search.")
                SettingsDivider()
                Label("Switched on in System Settings but still shown as missing here? That entry belongs to an older copy of TabWM. Click Reset, then Allow again.", systemImage: "lightbulb")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard("Startup", symbol: "power") {
                SettingRow("Open TabWM when you log in",
                           detail: "Starts TabWM automatically after you turn on your Mac, so your groups are always ready.") {
                    Toggle("", isOn: $controller.settings.launchAtLogin).toggleStyle(.switch).labelsHidden()
                }
                if let message = controller.loginItemMessage {
                    Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsCard("Back up settings", symbol: "square.and.arrow.up.on.square") {
                SettingRow("Save or load your settings",
                           detail: "Saves every choice on these pages (grouping, ignored apps, frame style, sizes, leader key, and all shortcuts) to one readable TOML file, for example to copy them to another Mac. Importing replaces all your settings; anything the file leaves out goes back to its default. Groups and permissions aren't included.") {
                    HStack { Button("Export…") { controller.exportSettings() }; Button("Import…") { controller.importSettings() } }
                }
                SettingsDivider()
                SettingRow("Restore defaults",
                           detail: "Puts every setting on these pages back to how TabWM comes. Your groups and permissions stay as they are.") {
                    Button("Restore Defaults…") {
                        let alert = NSAlert()
                        alert.messageText = "Restore all settings to their defaults?"
                        alert.informativeText = "This resets grouping, ignored apps, appearance, the leader key, and every shortcut."
                        alert.addButton(withTitle: "Restore Defaults"); alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn { controller.restoreDefaultSettings() }
                    }
                }
                SettingsDivider()
                SettingRow("Settings file",
                           detail: "Every setting on these pages lives in one file: \(controller.settingsURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Edit it in any text editor and TabWM applies the changes as soon as you save.") {
                    Button("Show in Finder") { controller.revealSettingsFile() }
                }
            }
        }
    }
    func permissionRow(_ permission: Permission, granted: Bool, title: String? = nil, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2).foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title ?? (permission == .inputMonitoring ? "Input Monitoring" : permission.rawValue)).font(.headline)
                    Text(granted ? "Allowed" : "Not allowed").font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((granted ? Color.green : Color.orange).opacity(0.15), in: Capsule())
                        .foregroundStyle(granted ? Color.green : Color.orange)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if !granted {
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Allow…") { permission.request(); controller.applySettings() }
                        .buttonStyle(.borderedProminent)
                        .help("Asks macOS for access. If macOS doesn't ask, opens System Settings.")
                    Button("Reset") { permission.reset(); controller.applySettings() }
                        .help("Removes TabWM's old entry so macOS asks again.")
                }
            }
        }
    }

    // MARK: Grouping

    var grouping: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Making groups", symbol: "rectangle.stack.badge.plus") {
                SettingRow("New windows",
                           detail: "What happens when you open a new window, for example a new Finder or browser window. “Join” adds it as a new tab to the group you were just using.") {
                    Picker("", selection: $controller.settings.newWindowPolicy) {
                        Text("Join my current group").tag("focused")
                        Text("Stay on their own").tag("off")
                    }.labelsHidden().fixedSize()
                }
                SettingsDivider()
                SettingRow("Wait before grouping",
                           detail: "When you drag a window onto another, TabWM waits this long before showing the blue “Release to group” box. A short wait means windows you only pass over on the way aren't grouped by accident.") {
                    HStack {
                        Slider(value: $controller.settings.holdDelay, in: 0...1.5, step: 0.05).frame(width: 160)
                        Text(String(format: "%.2f s", controller.settings.holdDelay)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }
            SettingsCard("When a window leaves the screen", symbol: "rectangle.on.rectangle") {
                SettingRow("Full screen",
                           detail: "When a window in a group goes full screen (the green button). “Keep” leaves its tab in the group, paused, until it comes back. “Remove” takes it out of the group.") {
                    Picker("", selection: $controller.settings.fullscreenPolicy) {
                        Text("Keep its tab").tag("suspend"); Text("Remove from group").tag("detach")
                    }.labelsHidden().fixedSize()
                }
                SettingsDivider()
                SettingRow("Moved to another desktop",
                           detail: "When a window in a group is moved to another desktop (Space). “Keep” leaves its tab in the group, paused. “Remove” takes it out of the group.") {
                    Picker("", selection: $controller.settings.offSpacePolicy) {
                        Text("Keep its tab").tag("suspend"); Text("Remove from group").tag("detach")
                    }.labelsHidden().fixedSize()
                }
            }
            SettingsCard("Tab search", symbol: "magnifyingglass") {
                SettingRow("Search through your tabs",
                           detail: "Adds a 🔍 button to every tab strip and a shortcut that lets you find any grouped window by typing part of its name.") {
                    Toggle("", isOn: $controller.settings.searchEnabled).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsCard("Apps TabWM ignores", symbol: "nosign",
                         note: "Windows of these apps are never grouped, and never join a group by themselves. System parts of macOS (Dock, Spotlight, Control Center, …) and launchers are on this list from the start.") {
                if controller.settings.excludedBundleIDs.isEmpty {
                    Text("No apps are ignored.").foregroundStyle(.secondary)
                }
                ForEach(controller.settings.excludedBundleIDs, id: \.self) { id in
                    HStack(spacing: 10) {
                        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                        if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22) }
                        else { Image(systemName: "app.dashed").frame(width: 22, height: 22) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.appName(id, url))
                            Text(id).font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if AppSettings.defaultExcludedBundleIDs.contains(id) {
                            Text("Built in").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Remove") { controller.settings.excludedBundleIDs.removeAll { $0 == id } }
                    }
                }
                SettingsDivider()
                HStack {
                    Menu("Add an Open App…") {
                        ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier!) { if let id = app.bundleIdentifier, !controller.settings.excludedBundleIDs.contains(id) { controller.settings.excludedBundleIDs.append(id) } }
                        }
                    }.fixedSize()
                    Spacer()
                    let missing = AppSettings.defaultExcludedBundleIDs.filter { !controller.settings.excludedBundleIDs.contains($0) }
                    if !missing.isEmpty {
                        Button("Restore Built-in Apps") { controller.settings.excludedBundleIDs = missing + controller.settings.excludedBundleIDs }
                            .help("Adds back the system apps that are ignored by default")
                    }
                }
                DisclosureGroup("Advanced: add by bundle ID") {
                    HStack {
                        TextField("For example com.apple.Safari", text: $newExclusion).textFieldStyle(.roundedBorder)
                        Button("Add") { let id = newExclusion.trimmingCharacters(in: .whitespaces); if !id.isEmpty, !controller.settings.excludedBundleIDs.contains(id) { controller.settings.excludedBundleIDs.append(id); newExclusion = "" } }
                    }.padding(.top, 8)
                }.foregroundStyle(.secondary)
            }
        }
    }

    /// Readable names for system parts that aren't regular apps (no app bundle to name them).
    static let systemNames = [
        "com.apple.Spotlight": "Spotlight", "com.apple.WindowManager": "Stage Manager",
        "com.apple.controlcenter": "Control Center", "com.apple.dock": "Dock",
        "com.apple.notificationcenterui": "Notification Center", "com.apple.systempreferences": "System Settings",
        "com.apple.systemuiserver": "Menu Bar Extras", "com.apple.loginwindow": "Login Window",
        "com.apple.SecurityAgent": "Password Prompts", "com.apple.UserNotificationCenter": "System Alerts",
        "com.apple.screencaptureui": "Screenshot", "com.apple.ScreenSaver.Engine": "Screen Saver",
        "com.apple.PIPAgent": "Picture in Picture", "com.apple.Siri": "Siri",
        "com.apple.CharacterPaletteIM": "Emoji & Symbols", "com.apple.TextInputMenuAgent": "Input Menu",
        "com.apple.AccessibilityUIServer": "Accessibility", "com.apple.coreservices.uiagent": "System Dialogs",
        "com.apple.ScreenContinuity": "iPhone Mirroring",
        "com.raycast.macos": "Raycast", "com.runningwithcrayons.Alfred": "Alfred",
    ]
    static func appName(_ id: String, _ url: URL?) -> String {
        if let name = systemNames[id] { return name }
        if let url { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        return id
    }

    // MARK: Appearance

    var appearance: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Frame style", symbol: "paintpalette",
                         note: "How the tab strip and the border around each group look. You can also change this from the ○ dot in any tab strip.") {
                FrameStylePicker(controller: controller)
            }
            SettingsCard("Colors", symbol: "circle.lefthalf.filled") {
                SettingRow("Theme",
                           detail: "Light or dark tab strips. “System” follows the setting in System Settings → Appearance. With Color, light uses Latte and dark uses Mocha.") {
                    Picker("", selection: $controller.settings.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                SettingsDivider()
                SettingRow("Transparency",
                           detail: "How see-through the tab strip and frame are. 100% is fully solid.") {
                    sliderControl(value: $controller.settings.tabBarOpacity, in: 0.3...1, step: 0.05, label: "\(Int(controller.settings.tabBarOpacity * 100))%")
                }
            }
            SettingsCard("Size", symbol: "ruler",
                         note: "Groups always fill the whole screen. A taller tab strip or a wider border leaves a little less room for the windows inside.") {
                SettingRow("Tab strip height",
                           detail: "How tall the bar with the tabs at the top of each group is.") {
                    sliderControl(value: $controller.settings.tabBarHeight, in: 24...42, step: 1, label: "\(Int(controller.settings.tabBarHeight)) pt")
                }
                SettingsDivider()
                SettingRow("Border width",
                           detail: "How thick the glass edge around the left, right, and bottom of a group is. 0 hides it.") {
                    sliderControl(value: $controller.settings.frameThickness, in: 0...10, step: 1, label: "\(Int(controller.settings.frameThickness)) pt")
                }
            }
            SettingsCard("Tabs", symbol: "app.badge") {
                SettingRow("Show notification badges",
                           detail: "Shows the same red number you see on an app's Dock icon (for example unread mail) on its tab.") {
                    Toggle("", isOn: $controller.settings.showBadges).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
    func sliderControl(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, label: String) -> some View {
        HStack {
            Slider(value: value, in: range, step: step).frame(width: 160)
            Text(label).monospacedDigit().frame(width: 52, alignment: .trailing)
            // Fine-tune one step at a time.
            Stepper("", value: value, in: range, step: step).labelsHidden()
        }
    }

    // MARK: Shortcuts

    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let problem = controller.shortcuts.problem {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Shortcuts are not working yet").font(.headline)
                        Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Allow Input Monitoring…") { Permission.inputMonitoring.request() }.buttonStyle(.borderedProminent)
                            Button("Reset") { Permission.inputMonitoring.reset() }
                        }
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            SettingsCard("Keys", symbol: "command",
                         note: "The leader key is the key you hold before every TabWM shortcut, like ⌘ for app shortcuts. It keeps TabWM's shortcuts from clashing with your apps.") {
                SettingRow("Leader key",
                           detail: "Hold this key, then press a shortcut key below. 🌐 Globe is the key at the bottom left of Mac keyboards.") {
                    Picker("", selection: $controller.settings.leaderKey) {
                        Section("Hold or tap") {
                            Text("🌐 Globe").tag("globe"); Text("Right ⌘").tag("rightCommand"); Text("Right ⌥").tag("rightOption"); Text("Right ⌃").tag("rightControl")
                        }
                        Section("Hold together") {
                            Text("⌃⌥").tag("controlOption"); Text("⌃⌥⌘").tag("controlOptionCommand"); Text("⌃⌥⇧⌘ (Hyper)").tag("hyper")
                        }
                        Text("Off").tag("off")
                    }.labelsHidden().fixedSize()
                }
                if AppSettings.leaderChords[controller.settings.leaderKey] == nil && controller.settings.leaderKey != "off" {
                    SettingsDivider()
                    SettingRow("Tap instead of hold",
                               detail: "Also lets you tap the leader key once, let go, and then press the shortcut key within a second. Handy if holding two keys is awkward.") {
                        Toggle("", isOn: $controller.settings.leaderSequence).toggleStyle(.switch).labelsHidden()
                    }
                }
                SettingsDivider()
                SettingRow("Grouping key",
                           detail: "Hold this key while you drag a window onto another window to put them in one group. Without it, dragging windows works as usual.") {
                    Picker("", selection: $controller.settings.modifier) {
                        Text("Leader key (\(KeyNames.leader(controller.settings.leaderKey)))").tag("leader")
                        Divider()
                        Text("⇧ Shift").tag("shift"); Text("⌃ Control").tag("control"); Text("⌥ Option").tag("option"); Text("⌘ Command").tag("command"); Text("None (any drag)").tag("none")
                    }.labelsHidden().fixedSize()
                }
                if controller.settings.leaderKey == "globe" {
                    SettingsDivider()
                    Label("Using 🌐? In System Settings → Keyboard, set “Press 🌐 key to” to “Do Nothing”, so macOS doesn't also open emoji or dictation.", systemImage: "lightbulb")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsCard("Shortcuts", symbol: "keyboard",
                         note: "Click a shortcut to record a new key. With “Use leader” ticked you press the leader key plus that key; untick it to record a full combination with ⌃, ⌥, or ⌘ instead. The switch turns a shortcut off.") {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                    if index > 0 { SettingsDivider() }
                    shortcutRow(action)
                }
                SettingsDivider()
                HStack { Spacer(); Button("Restore Defaults") { controller.settings.shortcuts = [:]; controller.settings.leaderKey = "globe"; controller.settings.modifier = "leader" } }
            }
        }
    }
    static let shortcutDetails: [ShortcutAction: String] = [
        .groupAll: "Puts every window on this desktop into one group.",
        .addTab: "Opens a list of your ungrouped windows to add as tabs to the group you're in.",
        .ungroup: "Splits up the group you're in. The windows stay open.",
        .search: "Opens a search box to find any tab by name.",
        .previousTab: "Shows the tab to the left in the current group.",
        .nextTab: "Shows the tab to the right in the current group.",
    ]
    func shortcutRow(_ action: ShortcutAction) -> some View {
        let binding = Binding<ShortcutBinding>(get: { controller.settings.binding(for: action) }, set: { controller.settings.setBinding($0, for: action) })
        return SettingRow(action.title, detail: Self.shortcutDetails[action] ?? "") {
            HStack(spacing: 12) {
                Toggle("Use leader", isOn: Binding(get: { binding.wrappedValue.usesLeader }, set: { uses in
                    var b = binding.wrappedValue; b.usesLeader = uses
                    // A standalone combo needs a modifier; start from the leader chord or ⌃⌥.
                    if uses { b.modifiers &= KeyModifier.shift }
                    else if b.modifiers & (KeyModifier.control | KeyModifier.option | KeyModifier.command) == 0 {
                        b.modifiers |= AppSettings.leaderChords[controller.settings.leaderKey] ?? (KeyModifier.control | KeyModifier.option)
                    }
                    binding.wrappedValue = b
                })).toggleStyle(.checkbox).help("Press the leader key together with this key")
                ShortcutRecorder(binding: binding, leader: controller.settings.leaderKey).frame(width: 150, height: 28)
                Toggle("", isOn: Binding(get: { binding.wrappedValue.enabled }, set: { var b = binding.wrappedValue; b.enabled = $0; binding.wrappedValue = b }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().help("Turn this shortcut on or off")
            }
        }
    }

    // MARK: How to Use

    var leaderName: String { KeyNames.leader(controller.settings.leaderKey) }
    func keys(_ action: ShortcutAction) -> String {
        let b = controller.settings.binding(for: action)
        return b.enabled ? KeyNames.describe(b, leader: controller.settings.leaderKey) : "(off)"
    }
    var groupingKey: String { controller.groupingKeyName }
    var tutorial: some View {
        VStack(alignment: .leading, spacing: 28) {
            HelpSection(title: "Getting started", symbol: "checklist") {
                HelpLine("Grant Accessibility in General. TabWM needs it to move, resize, focus, and close windows.")
                HelpLine("Grant Input Monitoring in General for keyboard shortcuts.")
                HelpLine("Turn off Stage Manager. Grouping is paused while it is on.")
            }
            HelpSection(title: "Making groups", symbol: "rectangle.stack.badge.plus") {
                HelpLine("Hold \(groupingKey) and drag a window over another window. Release when the blue preview appears.")
                HelpLine("To add a window to an existing group, drop it on the group's window or on its tab strip. With a maximized group, drop it on the tab strip.")
                HelpLine("\(keys(.groupAll)) groups every window on the current Space into the group you're in (or the window you're in).")
                HelpLine("Group Windows… in the menu bar lets you pick windows from a list, or group all windows of one app.")
                HelpLine("New windows join a group automatically: a window you open joins the group you were working in. Turn this off in Grouping → New windows.")
            }
            HelpSection(title: "The group frame", symbol: "macwindow") {
                HelpLine("Every group fills its screen, below the menu bar and above the Dock, inside one glass frame: tabs on top, a thin border around the rest.")
                HelpLine("Groups can't be moved or resized. Every window that joins takes the group's size.")
                HelpLine("Moving or resizing a grouped window (title bar, edges, zoom, tiling, window-manager shortcuts) takes it out of the group. It keeps its new size and position.")
                HelpLine("Use Move to Display in the tab strip to put a group on another screen.")
            }
            HelpSection(title: "Working with tabs", symbol: "square.on.square") {
                HelpLine("Click a tab to switch to its window. \(keys(.previousTab)) and \(keys(.nextTab)) step through the tabs of the group you're in.")
                HelpLine("Drag a tab sideways to reorder it, onto another group's tab strip to move it there, or away from the strip to detach it.")
                HelpLine("Hover a tab and click × to close that window.")
                HelpLine("Right-click a tab to activate, detach, close it, or move it to another group.")
            }
            HelpSection(title: "Managing groups", symbol: "slider.horizontal.3") {
                HelpLine("Right-click the tab strip to rename, lock, move to another display, add windows, ungroup, or close all windows.")
                HelpLine("\(keys(.ungroup)) ungroups the group you're in. Its windows stay where they are.")
                HelpLine("Locked groups can't be changed by dragging or ungrouping until you unlock them. A window in a locked group that gets moved or resized is put back.")
            }
            HelpSection(title: "Searching tabs", symbol: "magnifyingglass") {
                HelpLine("\(keys(.search)), the 🔍 button in a tab strip, or Search Tabs… in the menu bar opens search.")
                HelpLine("Type to filter by window title, app, or group name. Use ↑ ↓ to choose, ↩ to switch, ⎋ to close.")
                HelpLine("Grant Screen Recording in General to see a preview of the selected window.")
            }
            HelpSection(title: "Keyboard shortcuts", symbol: "keyboard") {
                HelpLine("Every shortcut starts with the leader key, \(leaderName), so they never clash with app shortcuts. Change the leader once in Shortcuts and every shortcut follows.")
                if AppSettings.leaderChords[controller.settings.leaderKey] == nil && controller.settings.leaderKey != "off" {
                    HelpLine("Hold \(leaderName) and press the key\(controller.settings.leaderSequence ? ", or tap \(leaderName) and press the key within a second" : "").")
                } else {
                    HelpLine("Hold \(leaderName) and press the key.")
                }
                if controller.settings.leaderKey == "globe" {
                    HelpLine("Using 🌐 as the leader: set System Settings → Keyboard → “Press 🌐 key to” → “Do Nothing”, so macOS doesn't also open the emoji picker or dictation.")
                }
                HelpLine("Any shortcut can skip the leader: untick Leader next to it and record a combo with ⌃, ⌥, or ⌘.")
            }
            HelpSection(title: "Full screen and Spaces", symbol: "rectangle.on.rectangle") {
                HelpLine("Windows that enter full screen or move to another Space are kept as suspended tabs or detached, depending on the Grouping settings.")
                HelpLine("Groups are restored after relaunching TabWM, as long as the Mac hasn't restarted.")
            }
        }
    }

    // MARK: About

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1"
    }

    var about: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("TabWM", symbol: "rectangle.stack") {
                SettingRow("Version \(Self.appVersion)", detail: "Groups your windows as tabs, like browser tabs, for any app on your Mac.") { EmptyView() }
            }
            SettingsCard("Something not working?", symbol: "stethoscope") {
                SettingRow("Copy diagnostics", detail: "Copies a short report (macOS version, permissions, number of windows and groups) that you can paste into a bug report. It contains no window titles.") {
                    copyDiagnosticsButton
                }
            }
        }
    }
    var copyDiagnosticsButton: some View {
        Button("Copy") { let text = "TabWM \(Self.appVersion)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nAccessibility: \(controller.system.accessibilityGranted)\nShortcuts: \(controller.shortcuts.isActive)\nWindows: \(controller.windows.count)\nGroups: \(controller.groups.count)\n\(controller.system.lastError ?? "")"; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); controller.status = "Diagnostics copied." }
    }
}

/// A titled, rounded section of a settings page, with an optional explanation underneath.
struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let note: String?
    @ViewBuilder var content: () -> Content
    init(_ title: String, symbol: String, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.note = note; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
                .padding(.top, 4)
        }
    }
}

/// One setting: what it is and what it does on the left, its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: () -> Control
    init(_ title: String, detail: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title; self.detail = detail; self.control = control
    }
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().padding(.vertical, 2) }
}

struct HelpSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
        }
    }
}

struct HelpLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.tertiary)
            Text(text).font(.body).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Window list panels (search and add)

/// Shared layout of the search and add-windows panels: search field on top, a narrow list on
/// the left, a large preview of the highlighted window on the right, and a footer.
struct WindowListPanel<Row: View, Footer: View>: View {
    @ObservedObject var controller: AppController
    let prompt: String
    @Binding var query: String
    let ids: [UInt32]
    @Binding var highlighted: UInt32?
    let emptyText: String
    let onSubmit: () -> Void
    let onClose: () -> Void
    @ViewBuilder var row: (UInt32, Bool) -> Row
    @ViewBuilder var footer: () -> Footer
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 12) {
            GlassSearchField(prompt: prompt, text: $query, large: true)
                .focused($searchFocused).onSubmit(onSubmit)
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if ids.isEmpty {
                        Text(emptyText).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 2) {
                                    ForEach(ids, id: \.self) { id in row(id, highlighted == id).id(id) }
                                }
                            }
                            .scrollContentBackground(.hidden)
                            .onChange(of: highlighted) { _, id in if let id { withAnimation(.snappy) { proxy.scrollTo(id) } } }
                        }
                    }
                }
                .frame(width: 230)
                WindowPreviewPane(controller: controller, windowID: highlighted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer()
        }
        .padding(16)
        .onAppear { searchFocused = true; if highlighted == nil { highlighted = ids.first } }
        .onChange(of: ids) { _, ids in if highlighted.map({ !ids.contains($0) }) ?? true { highlighted = ids.first } }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
    }
    func move(_ delta: Int) {
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex(of: highlighted ?? 0) ?? 0
        highlighted = ids[max(0, min(ids.count - 1, index + delta))]
    }
}

/// One window in a list panel: icon, title, and a subtitle; highlighted rows are tinted.
struct WindowListRow<Accessory: View>: View {
    @ObservedObject var controller: AppController
    let id: UInt32
    let subtitle: String
    let highlighted: Bool
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        let w = controller.window(id)
        HStack(spacing: 8) {
            if let icon = controller.system.appIcon(id) { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.tabTitle(id)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle.isEmpty ? (w?.appName ?? "") : subtitle)
                    .font(.system(size: 10.5)).foregroundStyle(highlighted ? .primary : .secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(highlighted ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// The highlighted window's live picture, centered and as large as the pane allows (a fixed
/// margin inside the pane), in the window's own proportions.
struct WindowPreviewPane: View {
    @ObservedObject var controller: AppController
    let windowID: UInt32?
    @State private var image: NSImage?
    static let inset: CGFloat = 10
    static let radius: CGFloat = 18
    var body: some View {
        let inner = RoundedRectangle(cornerRadius: Self.radius - Self.inset, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(inner)
                    .overlay { inner.strokeBorder(Color.primary.opacity(0.1)) }
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow").font(.system(size: 34)).foregroundStyle(.tertiary)
                    if !CGPreflightScreenCaptureAccess() {
                        Text("Allow Screen Recording in Settings → General to see previews.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                    }
                }
            }
        }
        .padding(Self.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous), clear: true)
        .task(id: windowID) {
            guard let windowID else { image = nil; return }
            let next = await controller.system.thumbnail(windowID)
            // Keep the previous picture until the next one is ready, so it doesn't flicker.
            if !Task.isCancelled { image = next }
        }
    }
}

struct WindowPickerView: View {
    @ObservedObject var controller: AppController
    let target: UInt32?
    @State private var selected = Set<UInt32>()
    @State private var highlighted: UInt32?
    @State private var query = ""
    /// Only ungrouped windows: grouped ones already have a home, and the target's own group
    /// can't take its members twice.
    var available: [WindowInfo] {
        controller.eligibleWindows.filter { w in
            w.id != target && controller.engine.group(containing: w.id) == nil &&
            (query.isEmpty || w.title.localizedCaseInsensitiveContains(query) || w.appName.localizedCaseInsensitiveContains(query))
        }
    }
    var verb: String { target == nil ? "Group" : "Add" }
    var minimum: Int { target == nil ? 2 : 1 }
    var chosen: [UInt32] { available.map(\.id).filter(selected.contains) }
    var body: some View {
        WindowListPanel(controller: controller,
                        prompt: target == nil ? "Find windows to group" : "Find windows to add",
                        query: $query, ids: available.map(\.id), highlighted: $highlighted,
                        emptyText: query.isEmpty ? "Every window is already in a group." : "No ungrouped window matches “\(query)”.",
                        onSubmit: submit, onClose: close) { id, isHighlighted in
            let isSelected = selected.contains(id)
            WindowListRow(controller: controller, id: id, subtitle: "", highlighted: isHighlighted) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15)).foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .onTapGesture { highlighted = id; toggle(id) }
        } footer: {
            HStack(spacing: 10) {
                Text("Click to tick · ↩ \(verb.lowercased())s \(chosen.isEmpty ? "all" : "ticked")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu("\(verb) by App") {
                    ForEach(available.map(\.appName).uniqued(), id: \.self) { name in
                        let ids = available.filter { $0.appName == name }.map(\.id)
                        Button("\(name) (\(ids.count))") { group(ids) }.disabled(ids.count < minimum)
                    }
                }
                .fixedSize().disabled(available.isEmpty)
                Button("\(verb) Selected") { group(chosen) }
                    .glassButtonStyle(prominent: !chosen.isEmpty)
                    .disabled(chosen.count < minimum)
                Button("\(verb) All") { group(available.map(\.id)) }
                    .glassButtonStyle(prominent: chosen.isEmpty)
                    .disabled(available.count < minimum)
            }
        }
        .onKeyPress(.space) { if let highlighted { toggle(highlighted) }; return .handled }
    }
    func toggle(_ id: UInt32) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    /// Return adds the ticked windows, or every listed window when none is ticked.
    func submit() {
        let ids = chosen.isEmpty ? available.map(\.id) : chosen
        if ids.count >= minimum { group(ids) }
    }
    func close() { controller.windowPicker?.close() }
    func group(_ ids: [UInt32]) {
        guard let anchor = target ?? ids.first else { return }
        for id in ids where id != anchor { controller.makeGroup(id, anchor) }
        close()
    }
}

struct SearchView: View {
    @ObservedObject var controller: AppController
    @State private var query = ""
    @State private var selected: UInt32?
    var entries: [(WindowInfo, TabWMCore.WindowGroup)] {
        controller.groups.flatMap { group in group.members.compactMap { id -> (WindowInfo, TabWMCore.WindowGroup)? in
            guard let w = controller.window(id), query.isEmpty || w.title.localizedCaseInsensitiveContains(query) || w.appName.localizedCaseInsensitiveContains(query) || group.name?.localizedCaseInsensitiveContains(query) == true else { return nil }; return (w, group)
        } }
    }
    var body: some View {
        let entries = entries
        WindowListPanel(controller: controller, prompt: "Search title, application, or group",
                        query: $query, ids: entries.map(\.0.id), highlighted: $selected,
                        emptyText: query.isEmpty ? "No grouped windows yet." : "No tab matches “\(query)”.",
                        onSubmit: activate, onClose: { controller.searchWindow?.close() }) { id, isHighlighted in
            let group = entries.first { $0.0.id == id }?.1
            let w = controller.window(id)
            WindowListRow(controller: controller, id: id,
                          subtitle: "\(w?.appName ?? "") · \(group.map { $0.name ?? controller.groupDesktops[$0.id] ?? "Group" } ?? "Group")\(group?.suspended.contains(id) == true ? " · Suspended" : "")",
                          highlighted: isHighlighted) { EmptyView() }
                .onTapGesture(count: 2) { controller.activate(id); controller.searchWindow?.close() }
                .simultaneousGesture(TapGesture().onEnded { selected = id })
        } footer: {
            HStack {
                Text("\(entries.count) tabs · ↑↓ to choose · ↩ to switch · ⎋ to close").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
    func activate() { if let selected { controller.activate(selected); controller.searchWindow?.close() } }
}
