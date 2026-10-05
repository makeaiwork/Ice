//
//  NativeMenuBarPolicy.swift
//  Ice
//

import Foundation
import CoreGraphics

/// Pure geometry and timing rules shared by the macOS 27 implementation/tests.
enum NativeMenuBarPolicy {
    /// A spacer must fit in the region to its left; macOS discards oversized
    /// items. Reserve room for Apple's overflow control. Coordinates are global.
    static func hidingLength(anchorX: CGFloat, display: CGRect, menuMaxX: CGFloat, notch: ClosedRange<CGFloat>?) -> CGFloat? {
        guard [anchorX, display.minX, display.maxX, menuMaxX].allSatisfy(\.isFinite),
              anchorX > display.minX, anchorX <= display.maxX else { return nil }
        let menuEnd = max(display.minX, menuMaxX)
        let length: CGFloat
        if let notch, anchorX >= notch.upperBound {
            let rightGap = anchorX - notch.upperBound
            let leftSpace = notch.lowerBound - menuEnd - 32
            length = leftSpace > rightGap ? leftSpace : rightGap - 32
        } else {
            length = anchorX - menuEnd - 32
        }
        return length >= 32 ? length : nil
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
