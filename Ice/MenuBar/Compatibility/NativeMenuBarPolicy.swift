//
//  NativeMenuBarPolicy.swift
//  Ice
//

import Foundation

enum NativeMenuBarSection: String, CaseIterable, Codable {
    case visible, hidden, alwaysHidden

    var title: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always-Hidden"
        }
    }
}

enum NativeMenuBarPolicy {
    static func sectionOnlyDrop(from source: NativeMenuBarSection, to destination: NativeMenuBarSection,
                                sourceRunning: Bool, targetRunning: Bool) -> Bool {
        source != destination && (!sourceRunning || !targetRunning)
    }

    static func canAssign(_ bundle: String, ownBundle: String) -> Bool {
        !bundle.isEmpty && bundle != ownBundle && ![
            "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
            "com.apple.SystemUIServer", "com.apple.TextInputMenuAgent",
        ].contains(bundle)
    }

    /// Recognized applications are hidden only through explicit membership.
    /// The native API may also hide items whose application identity is unknown.
    static func hiddenBundles(
        assignments: [String: NativeMenuBarSection], running: Set<String>, ownBundle: String,
        hidden: Bool, alwaysHidden: Bool, alwaysHiddenEnabled: Bool
    ) -> Set<String> {
        Set(assignments.compactMap { bundle, section in
            guard running.contains(bundle), canAssign(bundle, ownBundle: ownBundle) else { return nil }
            switch section {
            case .visible: return nil
            case .hidden: return hidden ? bundle : nil
            case .alwaysHidden: return alwaysHiddenEnabled && alwaysHidden ? bundle : nil
            }
        })
    }

    static func isInputIdle(buttons: Int, modifiers: UInt) -> Bool {
        buttons == 0 && modifiers == 0
    }
}

struct NativeRehideTimer {
    private var outsideSince: TimeInterval?

    mutating func reset() { outsideSince = nil }

    mutating func elapsed(now: TimeInterval, interval: TimeInterval, allowed: Bool) -> Bool {
        guard allowed, now.isFinite, interval.isFinite, interval >= 0 else {
            reset()
            return false
        }
        guard let outsideSince, now >= outsideSince else {
            self.outsideSince = now
            return false
        }
        return now - outsideSince >= interval
    }
}
