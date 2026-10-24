import Foundation
import CoreGraphics

/// Follows native macOS tabs (Finder, Safari, …): switching a native tab swaps the window
/// ID, so the group slot is rebound to the newly visible host.
/// Unknown AX verdicts may delay cleanup briefly but never authorize a rebind.
public final class NativeTabTracker {
    public struct Replacement {
        public let oldID: UInt32
        public let window: WindowInfo
        public let previousFrame: CGRect
    }
    public struct Resolution {
        public var replacements: [Replacement] = []
        public var preservedMembers: Set<UInt32> = []
    }
    private struct Member {
        var groupID: UUID
        var identity: WindowInfo
        var aliases: Set<UInt32>
        var pendingSince: TimeInterval?
    }
    private struct Proposal {
        var oldID: UInt32
        var host: WindowInfo
        var confirmed: Bool
        var member: Member
    }
    private var members: [UInt32: Member] = [:]
    /// How long an unresolved native-tab member is kept before it is treated as closed.
    public let unknownGrace: TimeInterval
    public init(unknownGrace: TimeInterval = 2) { self.unknownGrace = max(0, unknownGrace) }

    public func reconcile(engine: GroupEngine, windows: [WindowInfo], previousWindows: [WindowInfo] = [],
                          confirmedHosts: Set<UInt32>, unknownHosts: Set<UInt32> = [],
                          unavailablePIDs: Set<Int32> = [], deferredMembers: Set<UInt32> = [],
                          focusedWindowID: UInt32? = nil, now: TimeInterval) -> Resolution {
        var result = Resolution()
        let groups = engine.groups
        let grouped = Set(groups.flatMap(\.members))
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previous = Dictionary(previousWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        members = members.filter { id, member in
            groups.contains { $0.id == member.groupID && $0.members.contains(id) }
        }
        var proposals: [Proposal] = []
        for group in groups {
            for id in group.members {
                if members[id] == nil, let initial = previous[id] ?? byID[id] {
                    members[id] = Member(groupID: group.id, identity: initial, aliases: [id])
                }
                guard var member = members[id] else { continue }
                // Never use an old AX snapshot to bind a window in a restarted app.
                if let current = byID[id], !sameProcess(current, member.identity) {
                    continue
                }
                if unavailablePIDs.contains(member.identity.pid) {
                    result.preservedMembers.insert(id)
                    continue
                }
                if let current = byID[id], current.isOnScreen || current.isMinimized || current.isFullscreen {
                    member.identity = current
                    member.pendingSince = nil
                    // A former sibling that is now separately visible has detached.
                    member.aliases = member.aliases.filter { alias in
                        alias == id || byID[alias]?.isOnScreen != true
                    }
                    if current.isOnScreen && !confirmedHosts.contains(id) && !unknownHosts.contains(id) {
                        member.aliases = [id]
                    }
                    members[id] = member
                    continue
                }
                // A missing minimized/fullscreen snapshot is not a native switch.
                if byID[id] == nil && (member.identity.isMinimized || member.identity.isFullscreen) {
                    continue
                }
                let hosts = windows.filter { host in
                    guard host.id != 0, !grouped.contains(host.id), host.isOnScreen,
                          !host.isMinimized, !host.isFullscreen, sameProcess(host, member.identity) else { return false }
                    let familiar = member.aliases.contains(host.id)
                    let geometry = frameMatches(host.frame, member.identity.frame)
                        || byID[id].map { frameMatches(host.frame, $0.frame) } == true
                        || frameMatches(host.frame, group.frame)
                    // After closing a tab, a known sibling may be the last window and
                    // no longer advertise AXTabGroup. Require focus and geometry then.
                    let survivor = familiar && focusedWindowID == host.id && geometry
                    return (confirmedHosts.contains(host.id) || unknownHosts.contains(host.id) || survivor)
                        && (familiar || geometry)
                }
                guard hosts.count == 1, let host = hosts.first else {
                    member.pendingSince = nil
                    members[id] = member
                    continue
                }
                let confirmed = confirmedHosts.contains(host.id)
                    || (!unknownHosts.contains(host.id) && member.aliases.contains(host.id)
                        && focusedWindowID == host.id)
                proposals.append(Proposal(oldID: id, host: host, confirmed: confirmed, member: member))
            }
        }
        // Even a positive AX verdict cannot disambiguate two members claiming one host.
        let claims = Dictionary(grouping: proposals, by: { $0.host.id })
        for proposal in proposals {
            var member = proposal.member
            guard claims[proposal.host.id]?.count == 1 else {
                member.pendingSince = nil; members[proposal.oldID] = member
                continue
            }
            if deferredMembers.contains(proposal.oldID) {
                result.preservedMembers.insert(proposal.oldID)
                members[proposal.oldID] = member
                continue
            }
            if !proposal.confirmed {
                if member.pendingSince == nil { member.pendingSince = now }
                if now - (member.pendingSince ?? now) < unknownGrace {
                    result.preservedMembers.insert(proposal.oldID)
                }
                members[proposal.oldID] = member
                continue
            }
            guard engine.repointMember(proposal.oldID, to: proposal.host.id) else { continue }
            result.replacements.append(Replacement(oldID: proposal.oldID, window: proposal.host,
                                                   previousFrame: member.identity.frame))
            member.aliases.insert(proposal.oldID)
            member.aliases.insert(proposal.host.id)
            if !confirmedHosts.contains(proposal.host.id) { member.aliases = [proposal.host.id] }
            member.identity = proposal.host
            member.pendingSince = nil
            members.removeValue(forKey: proposal.oldID)
            members[proposal.host.id] = member
        }
        return result
    }
    private func sameProcess(_ a: WindowInfo, _ b: WindowInfo) -> Bool {
        guard a.pid == b.pid, a.bundleID == b.bundleID else { return false }
        if let aStart = a.processStartedAt, let bStart = b.processStartedAt { return aStart == bStart }
        return true
    }
    private func frameMatches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
