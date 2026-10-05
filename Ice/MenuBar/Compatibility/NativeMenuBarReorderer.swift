//
//  NativeMenuBarReorderer.swift
//  Ice
//
// Coordinate-based Command-drag follows the macOS 27 findings in fif7y/pelmet
// (GPL-3.0): Packages/PelmetEngine/Sources/PelmetEngine/ItemMover.swift.
// https://github.com/fif7y/pelmet

import Cocoa

@MainActor
enum NativeMenuBarReorderer {
    enum Failure: LocalizedError {
        case unavailable, busy, notVerified, inputUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "These icons are not available on the main menu bar. Open the apps and expand the macOS overflow, then try again."
            case .busy:
                "Release the mouse and modifier keys, then try again."
            case .notVerified:
                "macOS did not place all the icons in the requested position. The list shows their actual order. Try Command-dragging this app in the menu bar."
            case .inputUnavailable:
                "Ice could not start a menu bar drag. Check Accessibility permission."
            }
        }
    }

    static func move(
        bundle: String, relativeTo targetBundle: String, before: Bool,
        accessibility: MenuBarAccessibility, operation: NativeMenuBarOperation
    ) async throws {
        try operation.check()
        guard bundle != targetBundle, let display = NSScreen.screens.first.map({ CGDisplayBounds($0.displayID) }) else {
            throw Failure.unavailable
        }
        let allItems = await accessibility.items(applications: NSWorkspace.shared.runningApplications, displays: [display])
        try operation.check()
        let initial = rendered(allItems, display: display)
        let moving = initial.filter { $0.bundleID == bundle }
        let target = initial.filter { $0.bundleID == targetBundle }
        guard !moving.isEmpty, !target.isEmpty,
              allItems.filter({ $0.bundleID == bundle }).count == moving.count,
              allItems.filter({ $0.bundleID == targetBundle }).count == target.count,
              moving.allSatisfy({ usable($0, in: initial, display: display) }),
              target.allSatisfy({ usable($0, in: initial, display: display) }) else { throw Failure.unavailable }
        let movingIDs = moving.map(\.id)
        let targetIDs = target.map(\.id)
        if NativeMenuBarOrder.isPlaced(movingIDs, relativeTo: targetIDs, before: before, in: initial.map(\.id)) { return }

        // Inserting successively before the target preserves left-to-right order;
        // inserting after it requires visiting the source icons in reverse.
        for id in before ? movingIDs : movingIDs.reversed() {
            try operation.check()
            var landed = false
            for _ in 0..<2 {
                let current = await snapshot(accessibility, display: display)
                try operation.check()
                let anchorID = before ? targetIDs.first : targetIDs.last
                guard let item = current.first(where: { $0.id == id }),
                      let anchor = current.first(where: { $0.id == anchorID }),
                      usable(item, in: current, display: display), usable(anchor, in: current, display: display) else {
                    throw Failure.unavailable
                }
                if NativeMenuBarOrder.isPlaced([id], relativeTo: [anchor.id], before: before, in: current.map(\.id)) {
                    landed = true
                    break
                }
                // Aim inside the target's leading edge. A point one source-width
                // outside it skips a slot as MenuBarAgent reflows during a left move.
                let targetX = before ? anchor.frame.minX + 2 : anchor.frame.maxX + item.frame.width / 2 + 2
                guard targetX > display.minX + 100, targetX < display.maxX - 45 else { throw Failure.unavailable }
                try await drag(from: CGPoint(x: item.frame.midX, y: item.frame.midY),
                               to: CGPoint(x: targetX, y: anchor.frame.midY), operation: operation)
                try await Task.sleep(for: .milliseconds(450))
                let after = await snapshot(accessibility, display: display)
                try operation.check()
                let sourceIndex = after.firstIndex(where: { $0.id == id }) ?? -1
                let anchorIndex = after.firstIndex(where: { $0.id == anchor.id }) ?? -1
                Logger(category: "NativeMenuBar").info("Reorder placement: before=\(before), source index=\(sourceIndex), anchor index=\(anchorIndex), items=\(after.count)")
                if NativeMenuBarOrder.isPlaced([id], relativeTo: [anchor.id], before: before, in: after.map(\.id)) {
                    landed = true
                    break
                }
            }
            guard landed else { throw Failure.notVerified }
        }
        let final = await snapshot(accessibility, display: display)
        try operation.check()
        guard NativeMenuBarOrder.isPlaced(movingIDs, relativeTo: targetIDs, before: before, in: final.map(\.id)) else {
            throw Failure.notVerified
        }
    }

    private static func snapshot(_ accessibility: MenuBarAccessibility, display: CGRect) async -> [AccessibleMenuBarItem] {
        let items = await accessibility.items(applications: NSWorkspace.shared.runningApplications, displays: [display])
        return rendered(items, display: display)
    }

    private static func rendered(_ items: [AccessibleMenuBarItem], display: CGRect) -> [AccessibleMenuBarItem] {
        items.filter {
                $0.isHosted && $0.isDrawn && display.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) &&
                    $0.frame.midY < display.minY + 48
            }
            .sorted { $0.frame.midX < $1.frame.midX }
    }

    private static func usable(_ item: AccessibleMenuBarItem, in items: [AccessibleMenuBarItem], display: CGRect) -> Bool {
        let frame = item.frame
        guard frame.width > 0, frame.height > 0, frame.minX >= display.minX, frame.maxX <= display.maxX else { return false }
        // Overflowed items can share a frame. Never aim a drag at an ambiguous hit.
        return !items.contains {
            $0.id != item.id && $0.frame.intersection(frame).width > 4
        }
    }

    private static func drag(from start: CGPoint, to end: CGPoint, operation: NativeMenuBarOperation) async throws {
        try operation.check()
        guard NSEvent.pressedMouseButtons == 0,
              NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { throw Failure.busy }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let original = CGEvent(source: nil)?.location else { throw Failure.inputUnavailable }
        let tag: Int64 = 0x4943_454F // ICEO: distinguish our drag from physical input.
        source.userData = tag
        let originalFlags = CGEventFlags(rawValue: UInt64(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                   .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                   .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput ||
                event.getIntegerValueField(.eventSourceUserData) == 0x4943_454F {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }, userInfo: nil), let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            throw Failure.inputUnavailable
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        var lastPoint = start
        var mouseIsDown = false
        func post(_ type: CGEventType, at point: CGPoint) throws {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else { throw Failure.inputUnavailable }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
            lastPoint = point
        }
        // Every exit releases the button, cursor and tap, including cancellation.
        defer {
            if mouseIsDown { try? post(.leftMouseUp, at: lastPoint) }
            CGWarpMouseCursorPosition(original)
            // A mouse event alone does not update AppKit's cached modifier state.
            // Balance the synthetic Command flag explicitly before returning input.
            if let flags = CGEvent(source: source) {
                flags.type = .flagsChanged
                flags.flags = originalFlags
                flags.setIntegerValueField(.keyboardEventKeycode, value: 55)
                flags.post(tap: .cghidEventTap)
            }
            if let reset = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                   mouseCursorPosition: original, mouseButton: .left) {
                reset.flags = originalFlags
                reset.post(tap: .cghidEventTap)
            }
            CGAssociateMouseAndMouseCursorPosition(1)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        try post(.leftMouseDown, at: start)
        mouseIsDown = true
        try await Task.sleep(for: .milliseconds(180))
        let steps = min(30, max(6, Int(abs(end.x - start.x) / 30)))
        for step in 1...steps {
            try operation.check()
            guard CGEvent.tapIsEnabled(tap: tap) else { throw Failure.inputUnavailable }
            CGAssociateMouseAndMouseCursorPosition(0)
            let progress = CGFloat(step) / CGFloat(steps)
            try post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * progress,
                                                  y: start.y + (end.y - start.y) * progress))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(120))
        try operation.check()
        try post(.leftMouseUp, at: end)
        mouseIsDown = false
        try await Task.sleep(for: .milliseconds(60))
    }
}
