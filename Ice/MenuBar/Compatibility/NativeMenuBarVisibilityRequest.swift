//
//  NativeMenuBarVisibilityRequest.swift
//  Ice
//

import Foundation

/// User intent survives held mouse buttons and background refreshes. Revealing
/// items is safe during a drag; hiding waits for mouse-up, never for modifiers.
struct NativeMenuBarVisibilityRequest: Equatable {
    var hidden = false
    var alwaysHidden = false

    static let visible = Self()

    mutating func setHidden(_ hidden: Bool, alwaysHidden: Bool, alwaysHiddenEnabled: Bool) {
        if alwaysHidden {
            self.alwaysHidden = alwaysHiddenEnabled && hidden
            if !hidden { self.hidden = false }
        } else {
            self.hidden = hidden
            self.alwaysHidden = alwaysHiddenEnabled && (hidden || self.alwaysHidden)
        }
    }

    func canApply(over current: Self, pressedMouseButtons: Int) -> Bool {
        // Show All also cancels an unacknowledged hide while a drag starts.
        if self == .visible || pressedMouseButtons == 0 { return true }
        let reveals = (!hidden && current.hidden) || (!alwaysHidden && current.alwaysHidden)
        let hides = (hidden && !current.hidden) || (alwaysHidden && !current.alwaysHidden)
        return reveals && !hides
    }
}

/// Keep previously recognized bundle IDs allowed across app exits. Closing an
/// unrelated app must not replace an otherwise unchanged native assertion.
struct NativeMenuBarAllowlist {
    private var recognized = Set<String>()

    mutating func update(running: Set<String>, known: Set<String>, hidden: Set<String>) -> [String] {
        recognized.formUnion(running)
        recognized.formUnion(known)
        recognized.remove("")
        return recognized.subtracting(hidden).sorted()
    }
}
