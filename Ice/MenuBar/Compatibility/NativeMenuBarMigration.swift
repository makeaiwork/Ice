//
//  NativeMenuBarMigration.swift
//  Ice
//

import Foundation
import CoreGraphics

enum NativeMenuBarMigration {
    struct Item {
        let frame: CGRect
        let trusted: Bool
    }

    static func valid(_ item: Item, display: CGRect) -> Bool {
        let frame = item.frame
        guard item.trusted, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return false }
        return frame.width > 0 && frame.height > 0 && frame.height <= 48 &&
            frame.minX >= display.minX && frame.maxX <= display.maxX &&
            frame.minY >= display.minY && frame.maxY <= display.minY + 48
    }

    /// nil means the dividers cannot yet be used. Ambiguous apps stay visible.
    static func assignments(
        apps: [String: [Item]], hidden: Item, alwaysHidden: Item?, needsAlwaysHidden: Bool, display: CGRect
    ) -> [String: NativeMenuBarSection]? {
        guard valid(hidden, display: display) else { return nil }
        if needsAlwaysHidden {
            guard let alwaysHidden, valid(alwaysHidden, display: display),
                  alwaysHidden.frame.maxX <= hidden.frame.minX else { return nil }
        }
        return apps.mapValues { items in
            guard !items.isEmpty, items.allSatisfy({ valid($0, display: display) }) else { return .visible }
            if needsAlwaysHidden, let alwaysHidden, items.allSatisfy({ $0.frame.maxX <= alwaysHidden.frame.minX }) {
                return .alwaysHidden
            }
            return items.allSatisfy({ $0.frame.maxX <= hidden.frame.minX }) ? .hidden : .visible
        }
    }
}
