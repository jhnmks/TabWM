import XCTest
@testable import TabWMCore

final class GroupEngineTests: XCTestCase {
    func testMinimizingActiveSelectsEligibleRecentTab() {
        let engine=GroupEngine()
        engine.group(window(1),with:window(2));engine.group(window(3),with:window(2))
        engine.activate(1);engine.activate(3)
        var minimized=window(3);minimized.isMinimized=true
        engine.reconcile(windows:[window(1),window(2),minimized],settings:AppSettings())
        XCTAssertEqual(engine.groups[0].activeWindowID,1)
        XCTAssertEqual(engine.groups[0].minimized,[3])
    }
    func window(_ id: UInt32, onScreen: Bool = true) -> WindowInfo {
        WindowInfo(id: id, pid: 42, appName: "Editor", bundleID: "app.editor", title: "Document \(id)", frame: CGRect(x: 10, y: 20, width: 800, height: 600), isOnScreen: onScreen)
    }
    func testGroupingDoesNotDuplicateAndChoosesSuccessor() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2))
        engine.group(window(1), with: window(2))
        engine.group(window(3), with: window(1))
        XCTAssertEqual(engine.groups.count, 1)
        XCTAssertEqual(Set(engine.groups[0].members), [1, 2, 3])
        engine.detach(3)
        XCTAssertTrue(engine.groups[0].members.contains(engine.groups[0].activeWindowID))
        engine.detach(1)
        XCTAssertTrue(engine.groups.isEmpty)
    }
    func testJoiningWindowsTakeTheExistingGroupFrame() {
        let engine = GroupEngine()
        var a = window(1); a.frame = CGRect(x: 100, y: 100, width: 900, height: 700)
        var b = window(2); b.frame = CGRect(x: 300, y: 50, width: 400, height: 300)
        var c = window(3); c.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        // Two loose windows: the new group takes the drop target's frame.
        engine.group(b, with: a)
        XCTAssertEqual(engine.groups[0].frame, a.frame)
        // A loose window dropped onto the group, or the group dropped onto a loose window:
        // either way the group keeps its frame.
        engine.group(c, with: a)
        XCTAssertEqual(engine.groups[0].frame, a.frame)
        var d = window(4); d.frame = CGRect(x: 5, y: 5, width: 300, height: 200)
        engine.group(a, with: d)
        XCTAssertEqual(engine.groups[0].frame, a.frame)
        XCTAssertEqual(Set(engine.groups[0].members), [1, 2, 3, 4])
    }
    func testLocksProtectExplicitEditsButNotDeadWindowCleanup() {
        let engine = GroupEngine(); engine.group(window(1), with: window(2))
        let id = engine.groups[0].id
        engine.setLocked(id, locked: true)
        engine.detach(1); engine.dissolve(id); engine.dissolveAll(); engine.rename(id, name: "changed")
        engine.group(window(3), with: window(2))
        XCTAssertEqual(engine.groups[0].members.count, 2)
        XCTAssertNil(engine.groups[0].name)
        engine.activate(2); XCTAssertEqual(engine.groups[0].activeWindowID, 2)
        for _ in 0..<engine.missingSweepLimit { engine.reconcile(windows: [window(1)], settings: AppSettings()) }
        XCTAssertTrue(engine.groups.isEmpty)
    }
    func testReconcileCleansMultipleGroupsWithoutIndexCorruption() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2)); engine.group(window(3), with: window(4))
        engine.group(window(5), with: window(6))
        for _ in 0..<engine.missingSweepLimit { engine.reconcile(windows: [window(5), window(6)], settings: AppSettings()) }
        XCTAssertEqual(engine.groups.count, 1)
        XCTAssertEqual(Set(engine.groups[0].members), [5, 6])
    }
    func testOffscreenSuspendsWithoutDestroying() {
        let engine = GroupEngine(); engine.group(window(1), with: window(2)); engine.group(window(3), with: window(2))
        var settings = AppSettings(); settings.offSpacePolicy = "detach"
        engine.reconcile(windows: [window(1, onScreen: false), window(2), window(3)], settings: settings)
        XCTAssertEqual(engine.groups[0].members.count, 3)
        XCTAssertEqual(engine.groups[0].suspended, [1])
        engine.reconcile(windows: [window(1), window(2), window(3)], settings: settings)
        XCTAssertTrue(engine.groups[0].suspended.isEmpty)
    }
    func testRestoreSanitizesAndMergeMaintainsUniqueness() {
        let engine = GroupEngine(); let frame = window(1).frame
        engine.restore([
            WindowGroup(members: [1, 1, 2], activeWindowID: 9, frame: frame, suspended: [99]),
            WindowGroup(members: [2, 3, 4], activeWindowID: 2, frame: frame),
            WindowGroup(members: [5], activeWindowID: 5, frame: frame)
        ])
        XCTAssertEqual(engine.groups.count, 2)
        XCTAssertEqual(engine.groups[0].members, [1,2]); XCTAssertEqual(engine.groups[1].members, [3,4])
        XCTAssertEqual(engine.groups[0].activeWindowID, 1)
        XCTAssertTrue(engine.groups[0].suspended.isEmpty)
        // Dropping a member of one group onto another merges the groups.
        engine.group(window(1), with: window(3))
        XCTAssertEqual(engine.groups.count, 1); XCTAssertEqual(Set(engine.groups[0].members), [1,2,3,4])
        engine.activate(99); engine.detach(99); engine.reorder(99, to: -100)
        XCTAssertEqual(engine.groups[0].members.count, 4)
    }
    func testSameGroupDropActivatesSourceIncludingLockedGroups() {
        let engine = GroupEngine(); engine.group(window(1), with: window(2))
        engine.activate(2); engine.group(window(1), with: window(2))
        XCTAssertEqual(engine.groups[0].activeWindowID, 1)
        engine.setLocked(engine.groups[0].id, locked: true)
        engine.group(window(2), with: window(1))
        XCTAssertEqual(engine.groups[0].activeWindowID, 2)
        XCTAssertEqual(engine.groups[0].members.count, 2)
    }
    func testDefaultEvictsOnSixthAbsentSweep() {
        let engine = GroupEngine()
        XCTAssertEqual(engine.missingSweepLimit, 6)
        engine.group(window(1), with: window(2))
        for _ in 0..<5 { engine.reconcile(windows: [window(2)], settings: AppSettings()) }
        XCTAssertEqual(engine.groups.count, 1)
        engine.reconcile(windows: [window(2)], settings: AppSettings())
        XCTAssertTrue(engine.groups.isEmpty)
    }
    func testEvictRemovesMemberImmediatelyEvenIfLocked() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2)); engine.group(window(3), with: window(2))
        engine.activate(1)
        let groupID = engine.groups[0].id
        engine.setLocked(groupID, locked: true)
        engine.evict(1)
        XCTAssertEqual(engine.groups.count, 1)
        XCTAssertEqual(Set(engine.groups[0].members), [2, 3])
        XCTAssertTrue(engine.groups[0].isLocked)
        XCTAssertTrue(engine.groups[0].members.contains(engine.groups[0].activeWindowID))
    }
    func testEvictDissolvesSingletonGroupImmediately() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2))
        engine.evict(1)
        XCTAssertTrue(engine.groups.isEmpty)
    }
    func testEvictAllRemovesMultipleMembersAtomically() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2)); engine.group(window(3), with: window(1))
        engine.group(window(4), with: window(5))
        var changeCount = 0
        engine.onChange = { changeCount += 1 }
        engine.evict(all: [1, 4])
        XCTAssertEqual(changeCount, 1)
        XCTAssertEqual(engine.groups.count, 1)
        XCTAssertEqual(Set(engine.groups[0].members), [2, 3])
    }
    func testMissingCensusToleranceResetsAfterLiveSighting() {
        let engine = GroupEngine(missingSweepLimit: 3)
        engine.group(window(1), with: window(2))
        engine.reconcile(windows: [window(2)], settings: AppSettings())
        engine.reconcile(windows: [window(2)], settings: AppSettings())
        XCTAssertEqual(engine.groups.count, 1)
        engine.reconcile(windows: [window(1), window(2)], settings: AppSettings())
        engine.reconcile(windows: [window(2)], settings: AppSettings())
        engine.reconcile(windows: [window(2)], settings: AppSettings())
        XCTAssertEqual(engine.groups.count, 1)
        engine.reconcile(windows: [window(2)], settings: AppSettings())
        XCTAssertTrue(engine.groups.isEmpty)
    }
    func testMRUSuccessorSkipsSuspendedAndMinimizedMembers() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2))
        engine.group(window(3), with: window(1)); engine.group(window(4), with: window(1))
        engine.activate(2); engine.activate(3); engine.activate(4); engine.activate(1)
        XCTAssertEqual(engine.groups[0].mru, [1, 4, 3, 2])
        var minimized = window(4); minimized.isMinimized = true
        engine.reconcile(windows: [window(1), window(2), window(3, onScreen: false), minimized], settings: AppSettings())
        engine.detach(1)
        XCTAssertEqual(engine.groups[0].activeWindowID, 2)
        XCTAssertEqual(engine.groups[0].mru, [2, 4, 3])
    }
    func testMRUFallsBackWhenAllRemainingMembersUnavailable() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2)); engine.group(window(3), with: window(1))
        engine.activate(2); engine.activate(3); engine.activate(1)
        engine.reconcile(windows: [window(1), window(2, onScreen: false), window(3, onScreen: false)], settings: AppSettings())
        engine.detach(1)
        XCTAssertEqual(engine.groups[0].activeWindowID, 3)
    }
    func testMRUSessionBackwardsCompatibilityAndSanitization() throws {
        let group = WindowGroup(members: [1, 2, 3], activeWindowID: 2, frame: window(1).frame, mru: [2, 3, 1])
        let encoded = try JSONEncoder().encode(group)
        XCTAssertEqual(try JSONDecoder().decode(WindowGroup.self, from: encoded), group)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "mru")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(WindowGroup.self, from: oldData)
        XCTAssertEqual(decoded.mru, [2, 1, 3])
        var invalid = group; invalid.mru = [99, 3, 3]
        let engine = GroupEngine(); engine.restore([invalid])
        XCTAssertEqual(engine.groups[0].mru, [2, 3, 1])
    }
    func testMoveMemberSelectsDonorSuccessorAtomically() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2)); engine.group(window(3), with: window(1))
        engine.group(window(4), with: window(5))
        let donorID = engine.group(containing: 1)!.id
        let destinationID = engine.group(containing: 4)!.id
        engine.rename(donorID, name: "Donor"); engine.rename(destinationID, name: "Destination")
        engine.activate(3); engine.activate(1)
        var notifications = 0; engine.onChange = { notifications += 1 }
        engine.moveMember(1, to: 4, atIndex: 1)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(engine.group(containing: 2)!.activeWindowID, 3)
        XCTAssertEqual(engine.group(containing: 2)!.name, "Donor")
        let destination = engine.group(containing: 1)!
        XCTAssertEqual(destination.members, [5, 1, 4])
        XCTAssertEqual(destination.activeWindowID, 1)
        XCTAssertEqual(destination.mru.first, 1)
        XCTAssertEqual(destination.name, "Destination")
    }
    func testMoveMemberDissolvesSingletonDonorAndGuardsLocks() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2)); engine.group(window(3), with: window(4))
        let donor = engine.group(containing: 1)!.id
        let destination = engine.group(containing: 3)!.id
        engine.setLocked(donor, locked: true)
        engine.moveMember(1, to: 3, atIndex: 0)
        XCTAssertEqual(engine.group(containing: 1)!.id, donor)
        engine.setLocked(donor, locked: false); engine.setLocked(destination, locked: true)
        engine.moveMember(1, to: 3, atIndex: 0)
        XCTAssertEqual(engine.group(containing: 1)!.id, donor)
        engine.setLocked(destination, locked: false)
        engine.moveMember(1, to: 3, atIndex: 999)
        XCTAssertEqual(engine.groups.count, 1)
        XCTAssertNil(engine.group(containing: 2))
        XCTAssertEqual(engine.groups[0].members, [4, 3, 1])
        engine.moveMember(1, to: 3, atIndex: -999)
        XCTAssertEqual(engine.groups[0].members, [1, 4, 3])
        engine.moveMember(99, to: 3, atIndex: 0)
        engine.moveMember(1, to: 99, atIndex: 0)
        XCTAssertEqual(engine.groups[0].members, [1, 4, 3])
    }
    func testLegacySettingsDecodeDefaultsAndExplicitDisabledShortcuts() throws {
        let empty = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, AppSettings())
        // Retired fields (separate shortcuts, language, badge color) are ignored, not fatal.
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(##"{"modifier":"option","searchEnabled":false,"nextShortcut":null,"language":"de","badgeColor":"#abcdef"}"##.utf8))
        XCTAssertEqual(legacy.modifier, "option")
        XCTAssertFalse(legacy.searchEnabled)
        XCTAssertEqual(legacy.binding(for: .nextTab), ShortcutBinding(keyCode: 124))
        XCTAssertEqual(legacy.tabBarOpacity, 1)
        XCTAssertEqual(legacy.offSpacePolicy, "suspend")
        // Older files get the default exclusions once; later removals are kept.
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"excludedBundleIDs":["app.mine"],"settingsRevision":2}"#.utf8))
        XCTAssertEqual(older.excludedBundleIDs, AppSettings.defaultExcludedBundleIDs + ["app.mine"])
        let trimmed = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"excludedBundleIDs":["app.mine"],"settingsRevision":3}"#.utf8))
        XCTAssertEqual(trimmed.excludedBundleIDs, ["app.mine"])
        let keptDetach = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"offSpacePolicy":"detach","settingsRevision":2}"#.utf8))
        XCTAssertEqual(keptDetach.offSpacePolicy, "detach")
        // Pre-revision files carrying the old Shift default move to the leader; later ones keep Shift.
        let oldDefault = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"modifier":"shift"}"#.utf8))
        XCTAssertEqual(oldDefault.modifier, "leader")
        let chosen = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"modifier":"shift","settingsRevision":1}"#.utf8))
        XCTAssertEqual(chosen.modifier, "shift")
    }
    func testShortcutsInheritLeaderAndStoreOnlyOverrides() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.binding(for: .groupAll), ShortcutBinding(keyCode: 5))
        XCTAssertTrue(ShortcutAction.allCases.allSatisfy { settings.binding(for: $0).usesLeader })
        settings.setBinding(ShortcutBinding(keyCode: 1, modifiers: KeyModifier.command | KeyModifier.option, usesLeader: false), for: .search)
        settings.setBinding(ShortcutBinding(keyCode: 32), for: .ungroup)
        XCTAssertEqual(settings.shortcuts.count, 1)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }
    /// Every setting must survive export and import. Each one is changed away from its default
    /// first, so a setting missing from the file shows up as a difference. Adding a setting to
    /// `AppSettings` without adding it here (and to `SettingsFile`) fails the count check.
    func testSettingsFileRoundTripsEverySetting() throws {
        var settings = AppSettings()
        settings.modifier = "option"; settings.holdDelay = 0.75
        settings.tabBarHeight = 40; settings.frameThickness = 0; settings.tabBarOpacity = 0.6
        settings.frameStyle = "catppuccin"; settings.frameColor = "teal"; settings.appearance = "dark"
        settings.showBadges = false; settings.searchEnabled = false
        settings.excludedBundleIDs = ["com.apple.dock", "app.mine"]
        settings.newWindowPolicy = "off"; settings.fullscreenPolicy = "detach"; settings.offSpacePolicy = "detach"
        settings.launchAtLogin = true; settings.leaderKey = "rightOption"; settings.leaderSequence = false
        settings.setBinding(ShortcutBinding(keyCode: 1, modifiers: KeyModifier.command | KeyModifier.option, usesLeader: false), for: .search)
        settings.setBinding(ShortcutBinding(keyCode: 17, enabled: false), for: .addTab)
        settings.setBinding(ShortcutBinding(keyCode: 124, modifiers: KeyModifier.shift), for: .nextTab)
        XCTAssertEqual(Mirror(reflecting: settings).children.count, 19)
        let text = SettingsFile.text(settings)
        XCTAssertEqual(try SettingsFile.settings(from: text), settings)
        // Only choices: no version or app name; keys in words; the leader written once.
        XCTAssertFalse(text.contains("version")); XCTAssertFalse(text.contains("🌐"))
        // Spacing is for looks; compare without it.
        let compact = text.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(compact.contains(#"leader="right-opt""#))
        XCTAssertTrue(compact.contains(#"next-tab="leader+shift+right""#))
        XCTAssertTrue(compact.contains(#"search="opt+cmd+S""#))
        XCTAssertTrue(compact.contains(#"add-windows="off""#))
        // Your own ignored apps are kept, after the built-in groups.
        XCTAssertTrue(text.contains("# Your apps"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try SettingsFile.save(settings, to: url)
        XCTAssertEqual(try SettingsFile.load(from: url), settings)
    }
    func testSettingsFileShowsColorOnlyForColorStyle() {
        var settings = AppSettings()
        XCTAssertEqual(settings.frameStyle, "glass")
        /// Setting lines only, without comments or spaces.
        func values(_ s: AppSettings) -> [String] {
            SettingsFile.text(s).components(separatedBy: "\n")
                .map { ($0.components(separatedBy: "#").first ?? "").replacingOccurrences(of: " ", with: "") }
        }
        XCTAssertFalse(values(settings).contains { $0.hasPrefix("color=") })
        settings.frameStyle = "catppuccin"
        XCTAssertTrue(values(settings).contains(#"color="mauve""#))
    }
    func testSettingsFileReadsHandEditedPartialAndBrokenFiles() throws {
        // A hand-written file: comments, any order, other spellings; the rest stays default.
        let edited = try SettingsFile.settings(from: """
            leader = "hyper"   # all shortcuts follow
            [shortcuts]
            search = "leader+F"
            ungroup = "Cmd + Option + U"
            [appearance]
            border-width = 99
            theme = "neon"
            """)
        XCTAssertEqual(edited.leaderKey, "hyper")
        XCTAssertEqual(edited.binding(for: .search), ShortcutBinding(keyCode: 3))
        XCTAssertEqual(edited.binding(for: .ungroup), ShortcutBinding(keyCode: 32, modifiers: KeyModifier.command | KeyModifier.option, usesLeader: false))
        XCTAssertEqual(edited.frameThickness, 10); XCTAssertEqual(edited.appearance, "system")
        XCTAssertEqual(edited.binding(for: .groupAll), AppSettings().binding(for: .groupAll))
        XCTAssertEqual(edited.excludedBundleIDs, AppSettings.defaultExcludedBundleIDs)
        // An empty file is all defaults.
        XCTAssertEqual(try SettingsFile.settings(from: ""), AppSettings())
        // Mistakes are reported, not silently dropped.
        let broken = ["leader = globe", "[grouping", "tab-search = maybe", "[shortcuts]\nsearch = \"leader+banana\""]
        for text in broken {
            var threw = false
            do { _ = try SettingsFile.settings(from: text) } catch { threw = true }
            XCTAssertTrue(threw)
        }
    }
    func testSettingsValidationRejectsInvalidValuesAndClampsGeometry() {
        var settings = AppSettings()
        settings.tabBarHeight = -100
        settings.tabBarOpacity = 10
        settings.frameThickness = 50
        settings.holdDelay = .nan
        settings.modifier = "invalid"
        settings.excludedBundleIDs = [" app.editor ", "app.editor", ""]
        settings.frameStyle = "neon"; settings.frameColor = "chartreuse"
        settings.leaderKey = "capsLock"
        settings.newWindowPolicy = "everything"
        settings.shortcuts = [
            ShortcutAction.nextTab.rawValue: ShortcutBinding(keyCode: 1000),
            ShortcutAction.search.rawValue: ShortcutBinding(keyCode: 1, modifiers: KeyModifier.command | KeyModifier.shift),
            ShortcutAction.ungroup.rawValue: ShortcutBinding(keyCode: 32, usesLeader: false),
            ShortcutAction.previousTab.rawValue: ShortcutBinding(keyCode: 123, modifiers: KeyModifier.shift),
        ]
        settings.normalize()
        XCTAssertEqual(settings.leaderKey, "globe")
        XCTAssertEqual(settings.newWindowPolicy, "focused")
        XCTAssertEqual(settings.binding(for: .nextTab), ShortcutBinding(keyCode: 124))
        XCTAssertEqual(settings.binding(for: .search), ShortcutBinding(keyCode: 1, modifiers: KeyModifier.shift))
        XCTAssertEqual(settings.binding(for: .ungroup), ShortcutBinding(keyCode: 32))
        XCTAssertEqual(settings.binding(for: .previousTab), ShortcutBinding(keyCode: 123, modifiers: KeyModifier.shift))
        XCTAssertEqual(settings.tabBarHeight, 24)
        XCTAssertEqual(settings.tabBarOpacity, 1)
        XCTAssertEqual(settings.frameThickness, 10)
        XCTAssertEqual(settings.holdDelay, AppSettings().holdDelay)
        XCTAssertEqual(settings.modifier, "leader")
        XCTAssertEqual(settings.excludedBundleIDs, ["app.editor"])
        XCTAssertEqual(settings.frameStyle, "glass")
        XCTAssertEqual(settings.frameColor, "mauve")
    }

    @discardableResult func nativeStep(_ tracker: NativeTabTracker, _ engine: GroupEngine,
                                      _ windows: [WindowInfo], confirmed: Set<UInt32> = [],
                                      unknown: Set<UInt32> = [], unavailable: Set<Int32> = [],
                                      deferred: Set<UInt32> = [], focused: UInt32? = nil,
                                      previous: [WindowInfo] = [], now: TimeInterval = 0) -> NativeTabTracker.Resolution {
        let result = tracker.reconcile(engine: engine, windows: windows, previousWindows: previous,
            confirmedHosts: confirmed, unknownHosts: unknown, unavailablePIDs: unavailable,
            deferredMembers: deferred, focusedWindowID: focused, now: now)
        engine.reconcile(windows: windows, settings: AppSettings(), preservingMissing: result.preservedMembers)
        return result
    }
    func testRepointLockedMemberPreservesSlotMetadataAndMRUAtomically() {
        let engine = GroupEngine()
        let original = WindowGroup(members: [1, 2, 3], activeWindowID: 2, frame: window(1).frame,
            name: "Work", isLocked: true,
            suspended: [2], minimized: [2], mru: [2, 3, 1])
        engine.restore([original])
        var notifications = 0; engine.onChange = { notifications += 1 }
        XCTAssertTrue(engine.repointMember(2, to: 4))
        var expected = original
        expected.members = [1, 4, 3]; expected.activeWindowID = 4; expected.mru = [4, 3, 1]
        expected.suspended = [4]; expected.minimized = [4]
        XCTAssertEqual(engine.groups[0], expected)
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(engine.repointMember(3, to: 5))
        XCTAssertEqual(engine.groups[0].activeWindowID, 4)
        XCTAssertEqual(engine.groups[0].mru, [4, 5, 1])
    }
    func testRepointRejectsCollisionsAndResetsMissingHistory() {
        let engine = GroupEngine()
        engine.group(window(1), with: window(2)); engine.group(window(3), with: window(4))
        let original = engine.groups
        XCTAssertFalse(engine.repointMember(1, to: 0))
        XCTAssertFalse(engine.repointMember(1, to: 1))
        XCTAssertFalse(engine.repointMember(1, to: 2))
        XCTAssertFalse(engine.repointMember(1, to: 3))
        XCTAssertFalse(engine.repointMember(99, to: 5))
        XCTAssertEqual(engine.groups, original)
        for _ in 0..<5 { engine.reconcile(windows: [window(2), window(3), window(4)], settings: AppSettings()) }
        XCTAssertTrue(engine.repointMember(1, to: 5))
        for _ in 0..<5 { engine.reconcile(windows: [window(2), window(3), window(4)], settings: AppSettings()) }
        XCTAssertEqual(engine.groups.count, 2)
        engine.reconcile(windows: [window(2), window(3), window(4)], settings: AppSettings())
        XCTAssertEqual(engine.groups.count, 1)
    }
    func testNativeSwitchAndReturnAfterStackMovementPreserveGroup() {
        let engine = GroupEngine(); let tracker = NativeTabTracker()
        engine.group(window(1), with: window(2))
        let original = engine.groups[0]
        nativeStep(tracker, engine, [window(1), window(2)], confirmed: [1])
        let switched = nativeStep(tracker, engine, [window(1, onScreen: false), window(2), window(3)], confirmed: [3])
        XCTAssertEqual(switched.replacements.count, 1)
        XCTAssertEqual(engine.groups[0].members, [2, 3])
        XCTAssertEqual(engine.groups[0].activeWindowID, 3)
        var moved = window(3); moved.frame.origin.x = 500
        nativeStep(tracker, engine, [window(2), moved], confirmed: [3])
        var returned = window(1); returned.frame.origin.x = 700
        let back = nativeStep(tracker, engine, [window(2), returned], confirmed: [1])
        XCTAssertEqual(back.replacements.count, 1)
        XCTAssertEqual(back.replacements[0].previousFrame, moved.frame)
        XCTAssertEqual(engine.groups[0], original)
        // Closing an old, invisible tab does not affect the current host.
        for n in 0..<8 { nativeStep(tracker, engine, [window(2), returned], confirmed: [1], now: Double(n)) }
        XCTAssertEqual(engine.groups[0].members, original.members)
    }
    func testNativeUnknownVerdictNeverRepointsAndPreservationExpires() {
        let engine = GroupEngine(); let tracker = NativeTabTracker(unknownGrace: 2)
        engine.group(window(1), with: window(2))
        nativeStep(tracker, engine, [window(1), window(2)], confirmed: [1])
        for n in 0..<8 {
            let result = nativeStep(tracker, engine, [window(2), window(3)], unknown: [3], now: Double(n) / 10)
            XCTAssertEqual(result.preservedMembers, [1]); XCTAssertTrue(result.replacements.isEmpty)
        }
        XCTAssertEqual(engine.groups[0].members, [2, 1])
        for n in 0..<6 {
            let result = nativeStep(tracker, engine, [window(2), window(3)], unknown: [3], now: 2 + Double(n))
            XCTAssertTrue(result.preservedMembers.isEmpty); XCTAssertTrue(result.replacements.isEmpty)
        }
        XCTAssertTrue(engine.groups.isEmpty)
    }
    func testNativeUnknownThenConfirmedAndGestureDeferral() {
        let engine = GroupEngine(); let tracker = NativeTabTracker()
        engine.group(window(1), with: window(2))
        nativeStep(tracker, engine, [window(1), window(2)])
        nativeStep(tracker, engine, [window(2), window(3)], unknown: [3])
        for n in 1..<8 {
            let deferred = nativeStep(tracker, engine, [window(2), window(3)], confirmed: [3], deferred: [1], now: Double(n))
            XCTAssertEqual(deferred.preservedMembers, [1]); XCTAssertTrue(deferred.replacements.isEmpty)
        }
        let confirmed = nativeStep(tracker, engine, [window(2), window(3)], confirmed: [3], now: 8)
        XCTAssertEqual(confirmed.replacements.count, 1)
        XCTAssertEqual(engine.groups[0].members, [2, 3])
    }
    func testNativeRejectsAmbiguousHostsAndMultipleMemberClaims() {
        let engine = GroupEngine(); let tracker = NativeTabTracker()
        engine.group(window(1), with: window(2))
        nativeStep(tracker, engine, [window(1), window(2)])
        let ambiguous = nativeStep(tracker, engine, [window(2), window(3), window(4)], confirmed: [3, 4])
        XCTAssertTrue(ambiguous.replacements.isEmpty); XCTAssertTrue(ambiguous.preservedMembers.isEmpty)
        let shared = nativeStep(tracker, engine, [window(1, onScreen: false), window(2, onScreen: false), window(3)], confirmed: [3])
        XCTAssertTrue(shared.replacements.isEmpty); XCTAssertTrue(shared.preservedMembers.isEmpty)
        XCTAssertEqual(engine.groups[0].members, [2, 1])
    }
    func testNativeRejectsWrongProcessGeometryAndGroupedDestination() {
        let engine = GroupEngine(); let tracker = NativeTabTracker()
        var initial = window(1); initial.processStartedAt = 100
        engine.group(initial, with: window(2))
        nativeStep(tracker, engine, [initial, window(2)])
        var host = window(3); host.pid = 43
        XCTAssertTrue(nativeStep(tracker, engine, [window(2), host], confirmed: [3]).replacements.isEmpty)
        host = window(3); host.bundleID = "another.app"
        XCTAssertTrue(nativeStep(tracker, engine, [window(2), host], confirmed: [3]).replacements.isEmpty)
        host = window(3); host.processStartedAt = 200
        XCTAssertTrue(nativeStep(tracker, engine, [window(2), host], confirmed: [3]).replacements.isEmpty)
        host = window(3); host.frame.origin.x += 2
        XCTAssertTrue(nativeStep(tracker, engine, [window(2), host], confirmed: [3]).replacements.isEmpty)
        engine.group(window(3), with: window(4))
        let grouped = nativeStep(tracker, engine, [window(1, onScreen: false), window(2), window(3), window(4)], confirmed: [3])
        XCTAssertTrue(grouped.replacements.isEmpty); XCTAssertTrue(grouped.preservedMembers.isEmpty)
        XCTAssertEqual(engine.group(containing: 1)!.members, [2, 1])
        XCTAssertEqual(engine.group(containing: 3)!.members, [4, 3])
    }
    func testNativeIncompleteCensusSurvivesButGenuineClosureEvicts() {
        let engine = GroupEngine(); let tracker = NativeTabTracker()
        engine.group(window(1), with: window(2))
        nativeStep(tracker, engine, [window(1), window(2)])
        for n in 0..<10 {
            let unavailable = nativeStep(tracker, engine, [], unavailable: [42], now: Double(n))
            XCTAssertEqual(unavailable.preservedMembers, [1, 2])
        }
        XCTAssertEqual(engine.groups.count, 1)
        for n in 0..<6 { nativeStep(tracker, engine, [window(2)], now: 10 + Double(n)) }
        XCTAssertTrue(engine.groups.isEmpty)
        XCTAssertTrue(nativeStep(tracker, engine, [window(3)], confirmed: [3], now: 20).replacements.isEmpty)
    }
    func testNativeLastKnownSiblingSurvivesClosingCurrentTab() {
        let engine = GroupEngine(); let tracker = NativeTabTracker()
        engine.group(window(1), with: window(2))
        nativeStep(tracker, engine, [window(1), window(2)], confirmed: [1])
        nativeStep(tracker, engine, [window(2), window(3)], confirmed: [3])
        // Unknown AX metadata is not proof, even for a focused former sibling.
        let unknown = nativeStep(tracker, engine, [window(1), window(2)], unknown: [1], focused: 1)
        XCTAssertTrue(unknown.replacements.isEmpty)
        let survivor = nativeStep(tracker, engine, [window(1), window(2)], focused: 1)
        XCTAssertEqual(survivor.replacements.count, 1)
        XCTAssertEqual(engine.groups[0].members, [2, 1])
        // An unrelated single window cannot become a native host.
        XCTAssertTrue(nativeStep(tracker, engine, [window(2), window(4)], focused: 4).replacements.isEmpty)
    }
    func testNativeVisibleDetachedSiblingAndNegativeVerdictClearAliases() {
        for positive in [true, false] {
            let engine = GroupEngine(); let tracker = NativeTabTracker()
            engine.group(window(1), with: window(2))
            nativeStep(tracker, engine, [window(1), window(2)], confirmed: [1])
            nativeStep(tracker, engine, [window(2), window(3)], confirmed: [3])
            // Both visible means detached; a negative host verdict means no native stack.
            nativeStep(tracker, engine, positive ? [window(1), window(2), window(3)] : [window(2), window(3)], confirmed: positive ? [3] : [])
            var detached = window(1); detached.frame.origin.x += 100
            let result = nativeStep(tracker, engine, [window(2), detached], confirmed: [1])
            XCTAssertTrue(result.replacements.isEmpty)
            XCTAssertEqual(engine.groups[0].members, [2, 3])
        }
    }
    func testNativeDoesNotRepointVisibleMinimizedOrFullscreenMembers() {
        for state in 0..<3 {
            let engine = GroupEngine(); let tracker = NativeTabTracker()
            var source = window(1)
            if state == 1 { source.isOnScreen = false; source.isMinimized = true }
            if state == 2 { source.isFullscreen = true }
            engine.group(source, with: window(2))
            let result = nativeStep(tracker, engine, [source, window(2), window(3)], confirmed: [3])
            XCTAssertTrue(result.replacements.isEmpty)
            XCTAssertEqual(engine.groups[0].members, [2, 1])
        }
    }
    func testNativeDoesNotReuseMemberIdentityAfterProcessRestart() {
        let engine = GroupEngine(); let tracker = NativeTabTracker()
        var source = window(1); source.processStartedAt = 100
        engine.group(source, with: window(2))
        nativeStep(tracker, engine, [source, window(2)])
        var reused = source; reused.processStartedAt = 200; reused.isOnScreen = false
        var host = window(3); host.processStartedAt = 200
        for n in 0..<8 {
            let result = nativeStep(tracker, engine, [reused, window(2), host], confirmed: [3], now: Double(n))
            XCTAssertTrue(result.replacements.isEmpty)
        }
        XCTAssertEqual(engine.groups[0].members, [2, 1])
    }
    func testNativeMissingMinimizedMemberDoesNotBindSameFrameHost() {
        let engine = GroupEngine(); let tracker = NativeTabTracker()
        var source = window(1, onScreen: false); source.isMinimized = true
        engine.group(source, with: window(2))
        nativeStep(tracker, engine, [source, window(2)])
        let result = nativeStep(tracker, engine, [window(2), window(3)], confirmed: [3])
        XCTAssertTrue(result.replacements.isEmpty)
    }
}
