//
//  NativeMenuBarController.swift
//  Ice
//

import Cocoa
import Combine

/// macOS 27 hosts status items in MenuBarAgent instead of individual CGWindows.
/// Keep this path separate from the window-based implementation for older macOS.
@MainActor
final class NativeMenuBarController: NSObject, ObservableObject {
    @Published private(set) var items = [AccessibleMenuBarItem]()
    @Published private(set) var isHidden = false
    @Published private(set) var isAlwaysHidden = false
    @Published private(set) var isLoading = true
    @Published private(set) var message: String?
    @Published private(set) var isEditing = false

    private weak var appState: AppState?
    private let accessibility = MenuBarAccessibility()
    private var controls = [String: NSStatusItem]()
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var rehideTimer = NativeRehideTimer()
    private var hoverTimer = NativeRehideTimer()
    private var restoreHidden = false
    private var restoreAlwaysHidden = false
    private var generation = 0
    private var isTransitioning = false
    private var lastScroll: TimeInterval = 0
    private var menuIsTracking = false
    private var dragWasActive = false
    private var cachedSections = [String: MenuBarSection.Name]()
    private let logger = Logger(category: "NativeMenuBar")

    init(appState: AppState) {
        self.appState = appState
    }

    private var general: GeneralSettingsManager? { appState?.settingsManager.generalSettingsManager }
    private var advanced: AdvancedSettingsManager? { appState?.settingsManager.advancedSettingsManager }

    func performSetup() {
        guard controls.isEmpty else { return }
        makeControl("SItem", identifier: "Ice.Control", title: "", position: 0)
        makeControl("HItem", identifier: "Ice.HiddenBoundary", title: "│", position: 1)
        updateConfiguration()

        appState?.settingsManager.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.updateConfiguration() }
            .store(in: &subscriptions)
        Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
            .store(in: &subscriptions)
        UniversalEventMonitor.publisher(for: [.leftMouseUp, .rightMouseUp, .scrollWheel])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, general?.autoRehide == true, general?.rehideStrategy == .focusedApp else { return }
                scheduleRehide()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menuIsTracking = true }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in self?.menuIsTracking = false }
            .store(in: &subscriptions)
        appState?.navigationState.$isSettingsPresented
            .sink { [weak self] presented in
                guard let self else { return }
                if !presented { endEditing() }
                else if appState?.navigationState.settingsNavigationIdentifier == .menuBarLayout { beginEditing() }
            }
            .store(in: &subscriptions)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(500))
            await refresh()
            setHidden(true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private func makeControl(_ name: String, identifier: String, title: String, position: CGFloat?) {
        if StatusItemDefaults[.preferredPosition, name] == nil, let position {
            StatusItemDefaults[.preferredPosition, name] = position
        }
        // Restore stale visibility flags left by older AppKit releases.
        StatusItemDefaults[.visible, name] = true
        UserDefaults.standard.set(true, forKey: "NSStatusItem VisibleCC \(name)")
        let item = NSStatusBar.system.statusItem(withLength: name == "SItem" ? NSStatusItem.squareLength : 18)
        item.autosaveName = name
        item.button?.title = title
        item.button?.setAccessibilityIdentifier(identifier)
        item.button?.setAccessibilityLabel(name == "SItem" ? "Ice" : (name == "HItem" ? "Hidden boundary" : "Always hidden boundary"))
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        controls[name] = item
    }

    private func updateConfiguration() {
        guard let general, let advanced else { return }
        controls["SItem"]?.isVisible = general.showIceIcon
        if advanced.enableAlwaysHiddenSection && controls["AHItem"] == nil {
            makeControl("AHItem", identifier: "Ice.AlwaysHiddenBoundary", title: "┊", position: nil)
        }
        if let item = controls["AHItem"], item.isVisible != advanced.enableAlwaysHiddenSection {
            let position: CGFloat? = StatusItemDefaults[.preferredPosition, "AHItem"]
            item.isVisible = advanced.enableAlwaysHiddenSection
            StatusItemDefaults[.preferredPosition, "AHItem"] = position
        }
        updateImages()
        rehideTimer.reset()
    }

    private func updateImages() {
        guard let general, let appState else { return }
        controls["SItem"]?.button?.image = (isHidden ? general.iceIcon.hidden : general.iceIcon.visible).nsImage(for: appState)
        controls["SItem"]?.button?.toolTip = isHidden ? "Show hidden menu bar items" : "Hide menu bar items"
        for name in ["HItem", "AHItem"] {
            let hidden = name == "HItem" ? isHidden : isAlwaysHidden
            let showDivider = isEditing || advanced?.showSectionDividers == true
            controls[name]?.button?.title = hidden || !showDivider ? "" : (name == "HItem" ? "│" : "┊")
            controls[name]?.button?.isEnabled = !hidden
        }
    }

    func toggle(alwaysHidden: Bool = false) {
        setHidden(alwaysHidden ? !isAlwaysHidden : !isHidden, alwaysHidden: alwaysHidden)
    }

    func setHidden(_ hidden: Bool, alwaysHidden: Bool = false) {
        guard !hidden || !isEditing else { return }
        let enabled = advanced?.enableAlwaysHiddenSection == true
        let desiredHidden = alwaysHidden ? (hidden && isHidden) : hidden
        let desiredAlwaysHidden = enabled && (alwaysHidden ? hidden : (hidden || isAlwaysHidden))
        generation += 1
        let operation = generation
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self else { return }
            isTransitioning = true
            defer { if generation == operation { isTransitioning = false } }
            rehideTimer.reset()
            if !desiredHidden && !desiredAlwaysHidden {
                reveal("HItem")
                isHidden = false
                reveal("AHItem")
                isAlwaysHidden = false
                message = nil
                updateImages()
                await refresh()
                return
            }
            // A hotkey or Option-click can still have its modifiers held down.
            // Wait for release before changing native layout, with a bounded wait.
            for _ in 0..<20 where !inputIdle {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
            guard inputIdle else { return }
            // Read geometry with narrow dividers. Never resize using an already
            // overflowed item's stale frame; native user drags can change order.
            reveal("HItem")
            reveal("AHItem")
            isHidden = false
            isAlwaysHidden = false
            try? await Task.sleep(for: .milliseconds(180))
            await refresh()
            guard !Task.isCancelled, generation == operation, inputIdle, !isEditing else {
                updateImages()
                return
            }
            let name = desiredHidden ? "HItem" : "AHItem"
            guard let boundary = boundary(name), boundary.isDrawn,
                  let screen = screen(containing: boundary.frame),
                  let item = controls[name] else {
                message = "The section divider is not visible. Open Menu Bar Layout and move it beside the items you want to hide."
                updateImages()
                return
            }
            let display = CGDisplayBounds(screen.displayID)
            let menuMaxX = appState?.menuBarManager.getApplicationMenuFrame(for: screen.displayID)?.maxX ?? display.minX + 300
            let notch: ClosedRange<CGFloat>?
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notch = left.maxX...right.minX
            } else { notch = nil }
            guard let length = NativeMenuBarPolicy.hidingLength(
                anchorX: boundary.frame.maxX, display: display, menuMaxX: menuMaxX, notch: notch
            ) else {
                message = "There is not enough menu bar space to hide this section. Move its divider to the right."
                updateImages()
                return
            }
            item.length = length
            isHidden = desiredHidden
            isAlwaysHidden = desiredAlwaysHidden
            updateImages()
            logger.info("Concealing \(name), spacer length \(length)")
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
            guard !Task.isCancelled, generation == operation else { return }
            if general?.showIceIcon == true, !items.contains(where: { $0.identifier == "Ice.Control" && $0.isDrawn }) {
                reveal(name)
                isHidden = false
                isAlwaysHidden = false
                message = "Ice could not keep its button visible. Move the Ice button to the right of the section divider using Command-drag."
                updateImages()
            } else { message = nil }
        }
    }

    private func reveal(_ name: String) {
        controls[name]?.length = name == "SItem" ? NSStatusItem.squareLength : 18
    }

    private func boundary(_ name: String) -> AccessibleMenuBarItem? {
        let identifier = name == "AHItem" ? "Ice.AlwaysHiddenBoundary" : "Ice.HiddenBoundary"
        return items.first { $0.identifier == identifier }
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { CGDisplayBounds($0.displayID).contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    private func refresh() async {
        items = await accessibility.items(
            applications: NSWorkspace.shared.runningApplications,
            displays: NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        )
        if !isHidden && !isAlwaysHidden, let hidden = boundary("HItem") {
            let always = advanced?.enableAlwaysHiddenSection == true ? boundary("AHItem") : nil
            for item in items where item.ownerPID != ProcessInfo.processInfo.processIdentifier {
                cachedSections[item.id] = if let always, item.frame.maxX <= always.frame.minX {
                    .alwaysHidden
                } else if item.frame.maxX <= hidden.frame.minX {
                    .hidden
                } else { .visible }
            }
        }
        isLoading = false
    }

    func sectionItems(_ section: MenuBarSection.Name) -> [AccessibleMenuBarItem] {
        items.filter { $0.ownerPID != ProcessInfo.processInfo.processIdentifier && cachedSections[$0.id] == section }
    }

    func beginEditing() {
        guard !isEditing else { return }
        restoreHidden = isHidden
        restoreAlwaysHidden = isAlwaysHidden
        isEditing = true
        setHidden(false, alwaysHidden: true)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        updateImages()
        if restoreHidden || restoreAlwaysHidden { setHidden(true, alwaysHidden: !restoreHidden && restoreAlwaysHidden) }
    }

    private var inputIdle: Bool {
        NativeMenuBarPolicy.isInputIdle(
            buttons: NSEvent.pressedMouseButtons,
            modifiers: NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
        )
    }

    private var pointerInMenuBar: Bool {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.contains {
            CGRect(x: $0.frame.minX, y: $0.frame.maxY - max(24, $0.safeAreaInsets.top), width: $0.frame.width,
                   height: max(24, $0.safeAreaInsets.top)).contains(point)
        }
    }

    private var hasOpenMenu: Bool {
        if menuIsTracking { return true }
        // Menus can remain open after mouse-up and belong to another process.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
    }

    private func scheduleRehide() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, general?.autoRehide == true, !isHidden, !isTransitioning, !isEditing, !pointerInMenuBar,
                  inputIdle, !hasOpenMenu else { return }
            setHidden(true)
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dragging = NSEvent.modifierFlags.contains(.command) && NSEvent.pressedMouseButtons != 0 && pointerInMenuBar
        if dragging && !dragWasActive && advanced?.showAllSectionsOnUserDrag == true {
            setHidden(false, alwaysHidden: true)
        }
        dragWasActive = dragging
        let allowed = !isHidden && !isTransitioning && !isEditing && inputIdle && !pointerInMenuBar && !hasOpenMenu
        if rehideTimer.elapsed(now: now, interval: general?.rehideInterval ?? 0,
                              allowed: allowed && general?.autoRehide == true && general?.rehideStrategy == .timed) {
            setHidden(true)
        }
        if hoverTimer.elapsed(now: now, interval: advanced?.showOnHoverDelay ?? 0.2,
                              allowed: isHidden && !isTransitioning && general?.showOnHover == true && inputIdle && isEmptyMenuBarPoint) {
            setHidden(false)
        }
    }

    private var isEmptyMenuBarPoint: Bool {
        guard pointerInMenuBar, let top = NSScreen.screens.first?.frame.maxY else { return false }
        let point = CGPoint(x: NSEvent.mouseLocation.x, y: top - NSEvent.mouseLocation.y)
        guard let screen = NSScreen.screens.first(where: { CGDisplayBounds($0.displayID).contains(point) }),
              let menu = appState?.menuBarManager.getApplicationMenuFrame(for: screen.displayID), point.x > menu.maxX else { return false }
        return !items.contains { $0.isDrawn && $0.frame.insetBy(dx: -2, dy: 0).contains(point) }
    }

    private func handle(_ event: NSEvent) {
        guard !isEditing, inputIdle else { return }
        switch event.type {
        case .leftMouseUp:
            if isEmptyMenuBarPoint && general?.showOnClick == true { toggle() }
            else if !pointerInMenuBar && general?.autoRehide == true && general?.rehideStrategy == .smart { scheduleRehide() }
        case .rightMouseUp:
            if isEmptyMenuBarPoint && advanced?.showContextMenuOnRightClick == true { showMenu() }
        case .scrollWheel:
            let now = ProcessInfo.processInfo.systemUptime
            if pointerInMenuBar && general?.showOnScroll == true && abs(event.scrollingDeltaY) > 1 && now - lastScroll > 0.6 {
                lastScroll = now
                toggle()
            }
        default: break
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        toggle(alwaysHidden: advanced?.canToggleAlwaysHiddenSection == true && NSEvent.modifierFlags.contains(.option))
    }

    private func showMenu() {
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: isHidden ? "Show hidden items" : "Hide items", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Ice Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let quit = menu.addItem(withTitle: "Quit Ice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func openSettings() { appState?.appDelegate?.openSettingsWindow() }
}
