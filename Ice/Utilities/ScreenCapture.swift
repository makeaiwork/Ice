//
//  ScreenCapture.swift
//  Ice
//

import CoreGraphics
import ScreenCaptureKit

/// A namespace for screen capture operations.
enum ScreenCapture {
    /// Returns a Boolean value that indicates whether the app has been granted screen capture permissions.
    static func checkPermissions() -> Bool {
        if #available(macOS 27.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        for item in MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true) {
            // Don't check items owned by Ice.
            if item.owningApplication == .current {
                continue
            }
            return item.title != nil
        }
        // CGPreflightScreenCaptureAccess() only returns an initial value for whether the app
        // has permissions, but we can use it as a fallback.
        return CGPreflightScreenCaptureAccess()
    }

    /// Returns a Boolean value that indicates whether the app has been granted screen capture permissions.
    ///
    /// The first time this function is called, the permissions state is computed, cached, and returned.
    /// Subsequent calls either return the cached value, or recompute the permissions state before caching
    /// and returning it.
    static func cachedCheckPermissions(reset: Bool = false) -> Bool {
        enum Context {
            static var lastCheckResult: Bool?
        }

        if !reset {
            if let lastCheckResult = Context.lastCheckResult {
                return lastCheckResult
            }
        }

        let realResult = checkPermissions()
        Context.lastCheckResult = realResult
        return realResult
    }

    /// Requests screen capture permissions.
    static func requestPermissions() {
        if #available(macOS 15.0, *) {
            // CGRequestScreenCaptureAccess() is broken on macOS 15. SCShareableContent requires
            // screen capture permissions, and triggers a request if the user doesn't have them.
            SCShareableContent.getWithCompletionHandler { _, _ in }
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Captures only the wallpaper strip used to mask the menu bar's shape.
    /// Unlike the old WindowServer capture entry point, this works with the
    /// ScreenCaptureKit-backed desktop on current macOS.
    @MainActor
    static func captureWallpaperStrip(bounds: CGRect, scale: CGFloat) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
            guard let wallpaper = content.windows.first(where: {
                let owner = $0.owningApplication?.bundleIdentifier ?? ""
                let isWallpaper = $0.windowLayer == desktopLevel ||
                    owner == "com.apple.wallpaper.agent" ||
                    (owner == "com.apple.dock" && $0.title?.hasPrefix("Wallpaper") == true)
                return isWallpaper && $0.frame.contains(bounds)
            }) else {
                Logger(category: "MenuBarOverlayPanel").debug("Wallpaper window unavailable for appearance mask")
                return nil
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = bounds.offsetBy(dx: -wallpaper.frame.minX, dy: -wallpaper.frame.minY)
            configuration.width = Int(bounds.width * scale)
            configuration.height = Int(bounds.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: wallpaper)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            Logger(category: "MenuBarOverlayPanel").debug("Wallpaper capture unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Captures a composite image of an array of windows.
    ///
    /// - Parameters:
    ///   - windowIDs: The identifiers of the windows to capture.
    ///   - screenBounds: The bounds to capture. Pass `nil` to capture the minimum rectangle that encloses the windows.
    ///   - option: Options that specify the image to be captured.
    static func captureWindows(_ windowIDs: [CGWindowID], screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        let pointer = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: windowIDs.count)
        for (index, windowID) in windowIDs.enumerated() {
            pointer[index] = UnsafeRawPointer(bitPattern: UInt(windowID))
        }
        guard let windowArray = CFArrayCreate(kCFAllocatorDefault, pointer, windowIDs.count, nil) else {
            return nil
        }
        return .windowListImage(from: screenBounds ?? .null, windowArray: windowArray, imageOption: option)
    }

    /// Captures an image of a window.
    ///
    /// - Parameters:
    ///   - windowID: The identifier of the window to capture.
    ///   - screenBounds: The bounds to capture. Pass `nil` to capture the minimum rectangle that encloses the window.
    ///   - option: Options that specify the image to be captured.
    static func captureWindow(_ windowID: CGWindowID, screenBounds: CGRect? = nil, option: CGWindowImageOption = []) -> CGImage? {
        captureWindows([windowID], screenBounds: screenBounds, option: option)
    }
}

/// A protocol used to suppress deprecation warnings for the `CGWindowList` screen capture APIs.
///
/// ScreenCaptureKit doesn't support capturing composite images of offscreen menu bar items, but
/// this should be replaced once it does.
private protocol WindowListImage {
    init?(windowListFromArrayScreenBounds: CGRect, windowArray: CFArray, imageOption: CGWindowImageOption)
}

private extension WindowListImage {
    static func windowListImage(from screenBounds: CGRect, windowArray: CFArray, imageOption: CGWindowImageOption) -> Self? {
        Self(windowListFromArrayScreenBounds: screenBounds, windowArray: windowArray, imageOption: imageOption)
    }
}

extension CGImage: WindowListImage { }
