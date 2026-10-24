import AppKit
import ApplicationServices
import CoreGraphics

/// The macOS privacy permissions TabWM uses, and one place to ask for them.
///
/// Asking works in exactly one way per permission so the user never gets a system prompt and
/// a System Settings window at the same time:
/// - The first time, macOS shows its own prompt (which has its own "Open System Settings").
/// - If macOS won't prompt again (already decided, or an entry for an older build exists),
///   TabWM opens the right System Settings page instead.
enum Permission: String, CaseIterable {
    case accessibility = "Accessibility"
    case inputMonitoring = "ListenEvent"
    case screenRecording = "ScreenCapture"

    /// Service name for `tccutil reset`.
    var tccService: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "ListenEvent"
        case .screenRecording: return "ScreenCapture"
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    @MainActor private static var prompted: Set<Permission> = []

    @MainActor
    func request() {
        guard !isGranted else { return }
        if Self.prompted.insert(self).inserted {
            // macOS shows its prompt only if it hasn't recorded a decision for this build.
            switch self {
            case .accessibility:
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            case .inputMonitoring: _ = CGRequestListenEventAccess()
            case .screenRecording: _ = CGRequestScreenCaptureAccess()
            }
            // If no prompt appeared, nothing happens; the next click opens System Settings.
            return
        }
        openSettings()
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Removes TabWM's entry so macOS asks again from scratch. Needed when System Settings
    /// shows TabWM switched on but macOS still refuses it: the entry belongs to an older build.
    @MainActor
    func reset() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", tccService, Bundle.main.bundleIdentifier ?? "dev.tabwm.TabWM"]
        try? task.run(); task.waitUntilExit()
        Self.prompted.remove(self)
        request()
    }
}
