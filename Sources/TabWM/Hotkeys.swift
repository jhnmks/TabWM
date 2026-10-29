import AppKit
import Carbon
import CoreGraphics
import SwiftUI
import TabWMCore
import os

/// `log stream --predicate 'subsystem == "dev.tabwm.TabWM"' --level debug` shows these.
let shortcutLog = Logger(subsystem: "dev.tabwm.TabWM", category: "shortcuts")

/// Every global shortcut goes through one session event tap. A binding is either the shared
/// leader plus a key (the default for every action), or a standalone combo the user chose.
/// Matched keystrokes are swallowed so they never reach the frontmost app. The tap runs on
/// its own thread so a busy main thread can't make typing stall.
@MainActor
final class ShortcutMonitor: ObservableObject {
    @Published private(set) var isActive = false
    private var engine: ShortcutEngine?
    let handler: (ShortcutAction) -> Void
    init(handler: @escaping (ShortcutAction) -> Void) { self.handler = handler }

    /// Why shortcuts aren't running, in words the user can act on; nil while active.
    @Published private(set) var problem: String?
    private var retryTimer: Timer?
    private var lastSettings: AppSettings?

    func configure(_ settings: AppSettings) {
        lastSettings = settings
        start(settings)
        // Granting Input Monitoring takes effect without a relaunch: keep retrying quietly.
        if !isActive && retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let settings = self.lastSettings else { return }
                    self.start(settings)
                    if self.isActive { self.retryTimer?.invalidate(); self.retryTimer = nil }
                }
            }
        }
    }

    private func start(_ settings: AppSettings) {
        defer {
            if isActive { problem = nil }
            else if !CGPreflightListenEventAccess() {
                problem = "Keyboard shortcuts need Input Monitoring. If TabWM already shows as on in System Settings, click Reset: that entry belongs to an older build."
            } else {
                problem = "macOS refused to start the keyboard listener. Quit and reopen TabWM."
            }
        }
        var leaderBindings: [KeyChord: ShortcutAction] = [:], directBindings: [KeyChord: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            if action == .search && !settings.searchEnabled { continue }
            let binding = settings.binding(for: action)
            guard binding.enabled else { continue }
            let chord = KeyChord(keyCode: binding.keyCode, modifiers: binding.modifiers)
            if binding.usesLeader { leaderBindings[chord] = action } else { directBindings[chord] = action }
        }
        let config = ShortcutConfig(leader: settings.leaderKey, chordModifiers: AppSettings.leaderChords[settings.leaderKey],
                                    sequence: settings.leaderSequence, leaderBindings: leaderBindings, directBindings: directBindings)
        if let engine { engine.update(config); isActive = engine.running; return }
        let engine = ShortcutEngine(config: config) { [weak self] action in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handler(action) } }
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { engine.run(ready: ready) }
        thread.name = "dev.tabwm.shortcuts"; thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if engine.running { self.engine = engine }
        isActive = engine.running
        shortcutLog.notice("keyboard listener \(engine.running ? "started" : "refused", privacy: .public); input monitoring preflight=\(CGPreflightListenEventAccess(), privacy: .public) leader=\(settings.leaderKey, privacy: .public)")
    }
    func stop() { retryTimer?.invalidate(); retryTimer = nil; engine?.stop(); engine = nil; isActive = false }
}

struct KeyChord: Hashable, Sendable { var keyCode: UInt32; var modifiers: UInt32 }
struct ShortcutConfig: Sendable {
    var leader: String
    /// Set for chord leaders such as ⌃⌥; nil for solo leaders and "off".
    var chordModifiers: UInt32?
    var sequence: Bool
    var leaderBindings: [KeyChord: ShortcutAction]
    var directBindings: [KeyChord: ShortcutAction]
}

/// Owned by the tap thread; `config` is the only state shared with the main thread.
final class ShortcutEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var config: ShortcutConfig
    private let fire: (ShortcutAction) -> Void
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private(set) var running = false
    // Tap-thread state for solo leaders.
    private var leaderDown = false
    private var usedWhileDown = false
    private var armedUntil: TimeInterval = 0
    private var leaderDownAt: TimeInterval = 0
    /// Key codes whose key-up must also be swallowed because we ate the key-down.
    private var swallowedKeys: Set<Int64> = []

    init(config: ShortcutConfig, fire: @escaping (ShortcutAction) -> Void) { self.config = config; self.fire = fire }
    func update(_ config: ShortcutConfig) { lock.lock(); self.config = config; lock.unlock() }
    private var current: ShortcutConfig { lock.lock(); defer { lock.unlock() }; return config }

    func run(ready: DispatchSemaphore) {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(mask),
                                    callback: { _, type, event, context in
                                        Unmanaged<ShortcutEngine>.fromOpaque(context!).takeUnretainedValue().handle(type, event)
                                    }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { ready.signal(); return }
        self.tap = tap; runLoop = CFRunLoopGetCurrent(); running = true
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ready.signal()
        CFRunLoopRun()
        running = false
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil; runLoop = nil
    }

    /// Device-dependent left/right modifier bits (IOKit NX_DEVICE*KEYMASK).
    private static let rightCommand: UInt64 = 0x10, rightOption: UInt64 = 0x40, rightControl: UInt64 = 0x2000
    /// For solo leaders: whether this flags-changed event pressed (true) or released (false) it.
    private func soloLeaderState(_ event: CGEvent, leader: String) -> Bool? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let raw = event.flags.rawValue
        switch leader {
        case "globe": return keyCode == 63 || keyCode == 179 ? event.flags.contains(.maskSecondaryFn) : nil
        case "rightCommand": return keyCode == 54 ? raw & Self.rightCommand != 0 : nil
        case "rightOption": return keyCode == 61 ? raw & Self.rightOption != 0 : nil
        case "rightControl": return keyCode == 62 ? raw & Self.rightControl != 0 : nil
        default: return nil
        }
    }
    /// Carbon-style mask of the standard modifiers held for this event.
    private static func modifiers(_ flags: CGEventFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.maskCommand) { m |= KeyModifier.command }
        if flags.contains(.maskShift) { m |= KeyModifier.shift }
        if flags.contains(.maskAlternate) { m |= KeyModifier.option }
        if flags.contains(.maskControl) { m |= KeyModifier.control }
        return m
    }
    private static let soloModifierMask: [String: UInt32] = ["rightCommand": KeyModifier.command, "rightOption": KeyModifier.option, "rightControl": KeyModifier.control]

    /// With Globe held, macOS reports the arrows as Home/End/Page Up/Page Down (the
    /// laptop fn-arrow mapping). Map them back so 🌐 ← / 🌐 → match ← / →.
    private static let globeNavigation: [Int64: Int64] = [115: 123, 119: 124, 116: 126, 121: 125]

    private func match(_ rawKeyCode: Int64, _ event: CGEvent, _ config: ShortcutConfig, now: TimeInterval) -> ShortcutAction? {
        let held = Self.modifiers(event.flags)
        var keyCode = rawKeyCode
        if config.leader == "globe", leaderDown || now < armedUntil, let arrow = Self.globeNavigation[rawKeyCode] { keyCode = arrow }
        let code = UInt32(keyCode)
        if let chord = config.chordModifiers {
            // Chord leader: the leader modifiers plus an optional Shift from the binding.
            if held & chord == chord, let action = config.leaderBindings[KeyChord(keyCode: code, modifiers: held & ~chord)] { return action }
        } else if config.leader != "off" {
            let holding = leaderDown, armed = now < armedUntil
            if holding || armed {
                armedUntil = 0
                if holding { usedWhileDown = true }
                // The right-hand leader itself shows up as its modifier; ignore it when matching.
                let extra = held & ~(holding ? (Self.soloModifierMask[config.leader] ?? 0) : 0)
                if let action = config.leaderBindings[KeyChord(keyCode: code, modifiers: extra & KeyModifier.leaderExtras)], extra & ~KeyModifier.leaderExtras == 0 { return action }
            }
        }
        return config.directBindings[KeyChord(keyCode: code, modifiers: held)]
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let config = current
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .flagsChanged:
            guard config.chordModifiers == nil else { break }
            if let down = soloLeaderState(event, leader: config.leader) {
                shortcutLog.debug("leader \(down ? "down" : "up", privacy: .public)")
                if down { leaderDown = true; usedWhileDown = false; leaderDownAt = now }
                else if leaderDown {
                    leaderDown = false
                    // A clean, short tap arms the one-shot sequence. Holding the leader for a
                    // while (e.g. while dragging a window to group it) or with the mouse down
                    // is not a tap.
                    let quick = now - leaderDownAt < 0.5
                    let mouseDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    armedUntil = config.sequence && !usedWhileDown && quick && !mouseDown ? now + 1.0 : 0
                }
            } else if !leaderDown { armedUntil = 0 }
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if leaderDown || now < armedUntil {
                shortcutLog.debug("key \(keyCode, privacy: .public) flags=\(String(event.flags.rawValue, radix: 16), privacy: .public) with leader")
            }
            if let action = match(keyCode, event, config, now: now) {
                shortcutLog.notice("shortcut \(action.rawValue, privacy: .public)")
                swallowedKeys.insert(keyCode)
                let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !repeating || action.repeats { fire(action) }
                return nil
            }
        case .keyUp:
            if swallowedKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil { return nil }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Display

enum KeyNames {
    static let special: [UInt32: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                           115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
    static func name(_ keyCode: UInt32) -> String {
        if let name = special[keyCode] { return name }
        // Shortcuts match the physical key, so name it with a Latin layout (the user's own
        // ASCII-capable layout, e.g. U.S. or German) rather than the active one, which may
        // be Greek, Russian, Japanese, and so on and would rename keys on every switch.
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0, length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer in
            UCKeyTranslate(buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
    static func modifiers(_ m: UInt32) -> String {
        "\(m & KeyModifier.control != 0 ? "⌃" : "")\(m & KeyModifier.option != 0 ? "⌥" : "")\(m & KeyModifier.shift != 0 ? "⇧" : "")\(m & KeyModifier.command != 0 ? "⌘" : "")"
    }
    static func leader(_ leader: String) -> String {
        switch leader {
        case "globe": return "🌐"
        case "rightCommand": return "right ⌘"
        case "rightOption": return "right ⌥"
        case "rightControl": return "right ⌃"
        case "off": return "—"
        default: return modifiers(AppSettings.leaderChords[leader] ?? 0)
        }
    }
    static func describe(_ binding: ShortcutBinding, leader: String) -> String {
        let key = modifiers(binding.modifiers) + name(binding.keyCode)
        return binding.usesLeader ? "\(Self.leader(leader)) \(key)" : key
    }
}

// MARK: - Recorder

/// Records one binding. In leader mode it takes a bare key (Shift and Control allowed); otherwise it
/// takes a full combo with Control, Option, or Command.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var binding: ShortcutBinding
    let leader: String
    func makeNSView(context: Context) -> ShortcutButton { let button = ShortcutButton(); update(button); return button }
    func updateNSView(_ view: ShortcutButton, context: Context) { update(view) }
    private func update(_ view: ShortcutButton) {
        view.binding = binding; view.leader = leader; view.onCapture = { binding = $0 }; view.updateTitle()
    }
}

final class ShortcutButton: NSButton {
    var binding = ShortcutBinding(keyCode: 0)
    var leader = "globe"
    var onCapture: ((ShortcutBinding) -> Void)?
    var recording = false
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(begin); bezelStyle = .rounded }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    @objc func begin() { recording = true; window?.makeFirstResponder(self); title = binding.usesLeader ? "Press a key…" : "Press shortcut…" }
    override func resignFirstResponder() -> Bool { recording = false; updateTitle(); return super.resignFirstResponder() }
    func updateTitle() {
        guard !recording else { return }
        title = binding.enabled ? KeyNames.describe(binding, leader: leader) : "Off"
        alphaValue = binding.enabled ? 1 : 0.6
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; updateTitle(); return }
        let f = event.modifierFlags
        var mods: UInt32 = 0
        if f.contains(.command) { mods |= KeyModifier.command }; if f.contains(.option) { mods |= KeyModifier.option }
        if f.contains(.control) { mods |= KeyModifier.control }; if f.contains(.shift) { mods |= KeyModifier.shift }
        var next = binding
        if binding.usesLeader {
            guard mods & ~KeyModifier.leaderExtras == 0 else { NSSound.beep(); return }
        } else {
            guard mods & (KeyModifier.command | KeyModifier.option | KeyModifier.control) != 0 else { NSSound.beep(); return }
        }
        var code = UInt32(event.keyCode)
        // Pressing 🌐 with an arrow while recording yields Home/End/Page keys; keep the arrow.
        if binding.usesLeader, f.contains(.function), let arrow = [115: 123, 119: 124, 116: 126, 121: 125][code] { code = UInt32(arrow) }
        next.keyCode = code; next.modifiers = mods; next.enabled = true
        recording = false; binding = next; onCapture?(next); updateTitle()
    }
}
