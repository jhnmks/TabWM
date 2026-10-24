import AppKit
import ApplicationServices
import Combine

/// Best-effort Dock accessibility labels. Missing labels mean unknown/no badge;
/// this is not an API for an application's internal unread count.
@MainActor
final class DockBadges: ObservableObject {
    @Published private(set) var counts: [String: String] = [:]
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func refresh() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            if !counts.isEmpty { counts = [:] }; return
        }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.02)
        let apps = NSWorkspace.shared.runningApplications
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var offset = 0
        var visited: [AXUIElement] = []
        var next: [String: String] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.20
        // Dock accessibility structure is undocumented. Bound depth, count and time;
        // never invoke actions, request trust or launch an app while inspecting it.
        while offset < queue.count, visited.count < 200, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[offset]; offset += 1
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            if attribute(kAXSubroleAttribute, of: element) as? String == "AXApplicationDockItem",
               let raw = attribute("AXStatusLabel", of: element) as? String {
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty, label.count <= 64 {
                    var bundleID: String?
                    if let url = attribute(kAXURLAttribute, of: element) as? URL, url.isFileURL {
                        bundleID = Bundle(url: url)?.bundleIdentifier
                    }
                    if bundleID == nil, let title = attribute(kAXTitleAttribute, of: element) as? String {
                        let matches = apps.filter { $0.localizedName == title }
                        if matches.count == 1 { bundleID = matches[0].bundleIdentifier }
                    }
                    if let bundleID { next[bundleID] = label }
                }
            }
            if depth < 5, queue.count < 200,
               let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(200 - queue.count).map { ($0, depth + 1) })
            }
        }
        // A partial traversal may omit badges; never retain stale values indefinitely.
        if next != counts { counts = next }
    }
}
