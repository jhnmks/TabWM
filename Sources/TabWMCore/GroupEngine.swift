import Foundation
import CoreGraphics

/// Group membership and tab state. Locking prevents explicit structure edits; liveness
/// cleanup still applies. Single-member groups are dissolved. The host owns all actual
/// window operations.
public final class GroupEngine {
    public private(set) var groups: [WindowGroup] = []
    public var onChange: (() -> Void)?
    /// A window must be missing from this many consecutive censuses before it is dropped.
    public let missingSweepLimit: Int
    private var missingSweeps: [UInt32: Int] = [:]
    public init(missingSweepLimit: Int = 6) { self.missingSweepLimit = max(1, missingSweepLimit) }
    /// Reject malformed/singleton groups and keep each window in its first valid group.
    public func restore(_ saved: [WindowGroup]) {
        change {
            groups = []; missingSweeps = [:]
            var windowIDs = Set<UInt32>(); var groupIDs = Set<UUID>()
            for var group in saved {
                guard !groupIDs.contains(group.id), group.frame.width > 0, group.frame.height > 0,
                      group.frame.origin.x.isFinite, group.frame.origin.y.isFinite,
                      group.frame.width.isFinite, group.frame.height.isFinite else { continue }
                var local = Set<UInt32>()
                group.members = group.members.filter { $0 != 0 && !windowIDs.contains($0) && local.insert($0).inserted }
                guard group.members.count >= 2 else { continue }
                if !group.members.contains(group.activeWindowID) { group.activeWindowID = group.members[0] }
                let valid = Set(group.members)
                group.suspended.formIntersection(valid); group.minimized.formIntersection(valid)
                groups.append(group); windowIDs.formUnion(valid); groupIDs.insert(group.id)
            }
        }
    }
    public func group(containing id: UInt32) -> WindowGroup? { groups.first { $0.members.contains(id) } }
    private func index(_ id: UInt32) -> Int? { groups.firstIndex { $0.members.contains(id) } }
    private func change(_ body: () -> Void) {
        let before = groups; body()
        for i in groups.indices {
            var seen = Set<UInt32>()
            let valid = Set(groups[i].members)
            groups[i].mru = ([groups[i].activeWindowID] + groups[i].mru + groups[i].members)
                .filter { valid.contains($0) && seen.insert($0).inserted }
        }
        let members = Set(groups.flatMap(\.members))
        missingSweeps = missingSweeps.filter { members.contains($0.key) }
        if before != groups { onChange?() }
    }
    /// Puts `source` and `target` in one group. An existing group never changes its frame:
    /// whatever joins it takes the group's size and position. Only two loose windows start a
    /// new group, which takes the frame of the window being dropped onto (`target`).
    public func group(_ source: WindowInfo, with target: WindowInfo) {
        guard source.id != 0, target.id != 0, source.id != target.id else { return }
        if let a = group(containing: source.id), let b = group(containing: target.id), a.id == b.id {
            activate(source.id); return
        }
        guard group(containing: source.id)?.isLocked != true, group(containing: target.id)?.isLocked != true else { return }
        change {
            if let a = index(source.id), let b = index(target.id) {
                mergeInternal(groups[a].id, into: groups[b].id)
            } else if let b = index(target.id) {
                groups[b].members.append(source.id); groups[b].activeWindowID = source.id
            } else if let a = index(source.id) {
                // A loose window joins the source's group; the group keeps its own frame.
                groups[a].members.append(target.id)
                groups[a].activeWindowID = source.id
            } else {
                groups.append(WindowGroup(members: [target.id, source.id], activeWindowID: source.id, frame: target.frame))
            }
        }
    }
    public func activate(_ id: UInt32) {
        guard let i = index(id) else { return }
        change { groups[i].activeWindowID = id; groups[i].minimized.remove(id) }
    }
    /// A native tab switch changes window identity, including in a locked group.
    /// Preserve the slot and its metadata and emit a single change notification.
    @discardableResult public func repointMember(_ id: UInt32, to replacement: UInt32) -> Bool {
        guard replacement != 0, replacement != id, index(replacement) == nil,
              let i = index(id), let slot = groups[i].members.firstIndex(of: id) else { return false }
        change {
            groups[i].members[slot] = replacement
            if groups[i].activeWindowID == id { groups[i].activeWindowID = replacement }
            groups[i].mru = groups[i].mru.map { $0 == id ? replacement : $0 }
            if groups[i].suspended.remove(id) != nil { groups[i].suspended.insert(replacement) }
            if groups[i].minimized.remove(id) != nil { groups[i].minimized.insert(replacement) }
            missingSweeps.removeValue(forKey: id)
            missingSweeps.removeValue(forKey: replacement)
        }
        return true
    }
    public func detach(_ id: UInt32) {
        guard let i = index(id), !groups[i].isLocked else { return }
        change { remove(id, at: i) }
    }
    /// Removes a member unconditionally, ignoring group locks (used when a window is destroyed).
    public func evict(_ id: UInt32) {
        guard let i = index(id) else { return }
        change { remove(id, at: i) }
    }
    /// Removes multiple members unconditionally, ignoring group locks (used when an app quits).
    public func evict(all ids: Set<UInt32>) {
        guard !ids.isEmpty else { return }
        change {
            for id in ids {
                if let i = index(id) {
                    remove(id, at: i)
                }
            }
        }
    }
    private func remove(_ id: UInt32, at i: Int) {
        groups[i].members.removeAll { $0 == id }
        groups[i].mru.removeAll { $0 == id }
        groups[i].suspended.remove(id); groups[i].minimized.remove(id)
        guard groups[i].members.count >= 2 else { groups.remove(at: i); return }
        if groups[i].activeWindowID == id {
            let available = groups[i].mru.first { !groups[i].suspended.contains($0) && !groups[i].minimized.contains($0) }
            groups[i].activeWindowID = available ?? groups[i].mru.first ?? groups[i].members[0]
        }
    }
    public func dissolve(_ id: UUID) {
        change { groups.removeAll { $0.id == id && !$0.isLocked } }
    }
    public func dissolveAll() { change { groups.removeAll { !$0.isLocked } } }
    public func rename(_ id: UUID, name: String?) {
        guard let i = groups.firstIndex(where: { $0.id == id }), !groups[i].isLocked else { return }
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        change { groups[i].name = value?.isEmpty == false ? value : nil }
    }
    public func setLocked(_ id: UUID, locked: Bool) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        change { groups[i].isLocked = locked }
    }
    public func reorder(_ id: UInt32, to position: Int) {
        guard let i = index(id), !groups[i].isLocked else { return }
        change {
            groups[i].members.removeAll { $0 == id }
            groups[i].members.insert(id, at: max(0, min(position, groups[i].members.count)))
        }
    }
    /// Transfer one tab without merging its entire donor group. Emits one change event.
    public func moveMember(_ id: UInt32, to target: UInt32, atIndex position: Int) {
        guard let donorIndex = index(id), let destinationIndex = index(target),
              !groups[donorIndex].isLocked, !groups[destinationIndex].isLocked else { return }
        if donorIndex == destinationIndex { reorder(id, to: position); return }
        let destinationID = groups[destinationIndex].id
        let wasSuspended = groups[donorIndex].suspended.contains(id)
        change {
            remove(id, at: donorIndex)
            // Removing a two-member donor can shift the destination's array index.
            guard let destination = groups.firstIndex(where: { $0.id == destinationID }) else { return }
            groups[destination].members.insert(id, at: max(0, min(position, groups[destination].members.count)))
            if wasSuspended { groups[destination].suspended.insert(id) }
            groups[destination].minimized.remove(id)
            groups[destination].activeWindowID = id
            groups[destination].mru.removeAll { $0 == id }
            groups[destination].mru.insert(id, at: 0)
        }
    }
    private func mergeInternal(_ source: UUID, into target: UUID) {
        guard source != target, let a = groups.firstIndex(where: { $0.id == source }), let b = groups.firstIndex(where: { $0.id == target }), !groups[a].isLocked, !groups[b].isLocked else { return }
        let donor = groups[a]
        groups[b].members.append(contentsOf: donor.members.filter { !groups[b].members.contains($0) })
        groups[b].mru.append(contentsOf: donor.mru)
        groups[b].suspended.formUnion(donor.suspended); groups[b].minimized.formUnion(donor.minimized)
        groups.remove(at: a)
    }
    public func updateFrame(_ id: UInt32, frame: CGRect) {
        guard frame.width > 0, frame.height > 0, frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite, let i = index(id) else { return }
        change { groups[i].frame = frame }
    }
    /// Missing IDs require consecutive absent censuses; a live sighting resets the count.
    /// Off-screen minimized windows remain members, independent of Space policy.
    /// isOnScreen alone cannot prove a Space transition, so off-screen windows suspend.
    /// The host must confirm a Space transition before calling detach for that policy.
    public func reconcile(windows: [WindowInfo], settings: AppSettings, preservingMissing: Set<UInt32> = []) {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        change {
            for i in groups.indices.reversed() {
                let groupID = groups[i].id
                let ids = groups[i].members
                for id in ids {
                    guard i < groups.count, groups[i].id == groupID else { break }
                    guard groups[i].members.contains(id) else { continue }
                    guard let window = byID[id] else {
                        if preservingMissing.contains(id) { continue }
                        missingSweeps[id, default: 0] += 1
                        if missingSweeps[id, default: 0] >= missingSweepLimit { remove(id, at: i) }
                        continue
                    }
                    missingSweeps.removeValue(forKey: id)
                    guard !settings.excludedBundleIDs.contains(window.bundleID) else {
                        remove(id, at: i); continue
                    }
                    let full = window.isFullscreen
                    let away = !window.isOnScreen && !window.isMinimized
                    if full && settings.fullscreenPolicy == "detach" {
                        remove(id, at: i); continue
                    }
                    if full || away { groups[i].suspended.insert(id) } else { groups[i].suspended.remove(id) }
                    if window.isMinimized { groups[i].minimized.insert(id) } else { groups[i].minimized.remove(id) }
                }
                if i < groups.count, groups[i].id == groupID,
                   groups[i].minimized.contains(groups[i].activeWindowID),
                   let successor = groups[i].mru.first(where: { !groups[i].minimized.contains($0) && !groups[i].suspended.contains($0) }) {
                    groups[i].activeWindowID = successor
                }
            }
        }
    }
}
