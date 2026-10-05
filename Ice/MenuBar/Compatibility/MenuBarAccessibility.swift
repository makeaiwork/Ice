//
//  MenuBarAccessibility.swift
//  Ice
//

import Cocoa

struct AccessibleMenuBarItem: Identifiable, @unchecked Sendable {
    let id: String
    let element: AXUIElement
    let ownerPID: pid_t
    let bundleID: String?
    let identifier: String?
    let title: String
    var frame: CGRect
    var isDrawn: Bool
    var isHosted: Bool
}

/// Serializes bounded AX reads away from the UI thread. MenuBarAgent owns the
/// rendered geometry on macOS 27; the original application's frame may be stale.
actor MenuBarAccessibility {
    private var identities = [(element: AXUIElement, id: String)]()

    func items(applications: [NSRunningApplication], displays: [CGRect]) -> [AccessibleMenuBarItem] {
        let geometry = Self.hostedGeometry(applications: applications)
        var result = [AccessibleMenuBarItem]()
        for app in applications where !app.isTerminated {
            if Task.isCancelled { return [] }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.08)
            guard let bar = Self.element("AXExtrasMenuBar", of: root) else { continue }
            var queue = [(bar, 0)]
            var visited = 0
            while !queue.isEmpty && visited < 128 {
                if Task.isCancelled { return [] }
                let (element, depth) = queue.removeFirst()
                visited += 1
                let role = Self.string(kAXRoleAttribute, of: element)
                if role == kAXMenuBarItemRole || role == kAXButtonRole {
                    guard let originalFrame = Self.frame(of: element) else { continue }
                    let identifier = Self.string(kAXIdentifierAttribute, of: element)
                    // Apple's overflow button belongs to the bar, not a section.
                    if app.bundleIdentifier == "com.apple.MenuBarAgent" { continue }
                    let hosted = geometry.first { entry in
                        CFEqual(entry.element, element) ||
                            (entry.pid == app.processIdentifier && identifier != nil && entry.identifier == identifier)
                    }
                    let frame = hosted?.frame ?? originalFrame
                    let isDrawn = displays.contains { display in
                        let strip = CGRect(x: display.minX, y: display.minY, width: display.width, height: 48)
                        return frame.width > 0 && frame.height > 0 && strip.intersects(frame)
                    } && !(hosted?.overflows ?? false)
                    let id: String
                    if let existing = identities.first(where: { CFEqual($0.element, element) }) {
                        id = existing.id
                    } else {
                        id = UUID().uuidString
                        identities.append((element, id))
                    }
                    let title = Self.string(kAXTitleAttribute, of: element)
                        ?? Self.string(kAXDescriptionAttribute, of: element)
                        ?? app.localizedName ?? "Menu bar item"
                    result.append(AccessibleMenuBarItem(
                        id: id, element: element, ownerPID: app.processIdentifier,
                        bundleID: app.bundleIdentifier, identifier: identifier,
                        title: title.isEmpty ? (app.localizedName ?? "Menu bar item") : title,
                        frame: frame, isDrawn: isDrawn, isHosted: hosted != nil
                    ))
                } else if depth < 3 {
                    queue.append(contentsOf: Self.children(of: element).map { ($0, depth + 1) })
                }
            }
        }
        let livePIDs = Set(applications.filter { !$0.isTerminated }.map(\.processIdentifier))
        identities.removeAll { entry in
            var pid: pid_t = 0
            return AXUIElementGetPid(entry.element, &pid) != .success || !livePIDs.contains(pid)
        }
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Only hosted, currently rendered frames are suitable for appearance masks.
    /// Original app AX frames can remain stale after an app is hidden.
    func appearanceFrames(display: CGRect, agents: [NSRunningApplication], menuOwnerPID: pid_t?) -> (application: CGRect?, items: [CGRect]) {
        let strip = CGRect(x: display.minX, y: display.minY, width: display.width, height: 80)
        var frames = [CGRect]()
        for agent in agents where agent.bundleIdentifier == "com.apple.MenuBarAgent" {
            let root = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.08)
            for window in Self.hostWindows(of: root) {
                for child in Self.children(of: window) {
                    if let frame = Self.frame(of: child), frame.width > 0, frame.width < display.width / 2,
                       frame.height > 0, frame.height < 80, strip.intersects(frame) {
                        frames.append(frame.intersection(strip))
                    }
                }
            }
        }
        var menuBars = [AXUIElement]()
        if let menuOwnerPID {
            let owner = AXUIElementCreateApplication(menuOwnerPID)
            AXUIElementSetMessagingTimeout(owner, 0.1)
            if let bar = Self.element(kAXMenuBarAttribute, of: owner) { menuBars.append(bar) }
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(display.minX + 15), Float(display.minY + 12), &hit) == .success {
            for _ in 0..<3 {
                guard let element = hit else { break }
                if Self.string(kAXRoleAttribute, of: element) == kAXMenuBarRole {
                    menuBars.append(element)
                    break
                }
                hit = Self.element(kAXParentAttribute, of: element)
            }
        }
        var application: CGRect?
        for bar in menuBars {
            let menus = Self.children(of: bar).compactMap { child -> CGRect? in
                guard Self.string(kAXRoleAttribute, of: child) == kAXMenuBarItemRole,
                      let frame = Self.frame(of: child), frame.width > 0, strip.intersects(frame) else { return nil }
                return frame
            }
            if !menus.isEmpty {
                application = menus.reduce(CGRect.null) { $0.union($1) }
                break
            }
        }
        return (application, frames)
    }

    func isEmptyMenuBar(at point: CGPoint) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return false }
        return Self.string(kAXRoleAttribute, of: element) == kAXMenuBarRole
    }

    func press(_ item: AccessibleMenuBarItem) -> Bool {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success ||
            AXUIElementPerformAction(item.element, kAXShowMenuAction as CFString) == .success
    }

    private struct HostedFrame {
        let element: AXUIElement
        let pid: pid_t
        let identifier: String?
        let frame: CGRect
        var overflows: Bool
    }

    private static func hostedGeometry(applications: [NSRunningApplication]) -> [HostedFrame] {
        var result = [HostedFrame]()
        for agent in applications where agent.bundleIdentifier == "com.apple.MenuBarAgent" {
            if Task.isCancelled { return [] }
            let root = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.08)
            for window in hostWindows(of: root) {
                let containers = children(of: window)
                let overflow = containers.filter {
                    string(kAXRoleAttribute, of: $0) == kAXButtonRole
                }.compactMap { frame(of: $0) }
                for container in containers {
                    if Task.isCancelled { return [] }
                    guard let bounds = frame(of: container) else { continue }
                    var queue = [(container, 0)]
                    var visited = 0
                    while !queue.isEmpty && visited < 32 {
                        let (element, depth) = queue.removeFirst()
                        visited += 1
                        var pid: pid_t = 0
                        AXUIElementGetPid(element, &pid)
                        let role = string(kAXRoleAttribute, of: element)
                        if pid != 0 && pid != agent.processIdentifier && (role == kAXButtonRole || role == kAXMenuBarItemRole) {
                            result.append(HostedFrame(
                                element: element, pid: pid,
                                identifier: string(kAXIdentifierAttribute, of: element),
                                frame: bounds, overflows: overflow.contains { $0.intersection(bounds).width > 6 }
                            ))
                            break
                        }
                        if depth < 5 {
                            if role == kAXApplicationRole, let extras = Self.element("AXExtrasMenuBar", of: element) {
                                queue.append((extras, depth + 1))
                            } else {
                                queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    private static func hostWindows(of root: AXUIElement) -> [AXUIElement] {
        // MenuBarAgent publishes its bar windows in AXChildren on macOS 27;
        // AXWindows can be empty even while the bar is visible.
        let windows = elements(kAXWindowsAttribute, of: root)
        return windows.isEmpty ? children(of: root).filter { string(kAXRoleAttribute, of: $0) == kAXWindowRole } : windows
    }

    nonisolated private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        value(attribute, of: element) as? String
    }

    nonisolated private static func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = value(attribute, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    nonisolated private static func elements(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        value(attribute, of: element) as? [AXUIElement] ?? []
    }

    nonisolated private static func children(of element: AXUIElement) -> [AXUIElement] {
        elements(kAXChildrenAttribute, of: element)
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(kAXPositionAttribute, of: element),
              let size = value(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions),
              [point.x, point.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
