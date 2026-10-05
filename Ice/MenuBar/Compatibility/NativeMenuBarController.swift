//
//  NativeMenuBarController.swift
//  Ice
//

import Cocoa
import Combine

struct NativeMenuBarApplication: Identifiable {
    let id: String
    var title: String
    var ownerPID: pid_t
}

/// macOS 27 visibility is controlled per application. Native assertions keep
/// hidden items out of MenuBarAgent instead of relying on oversized spacers.
@MainActor
final class NativeMenuBarController: NSObject, ObservableObject {
    @Published private(set) var applications = [NativeMenuBarApplication]()
    @Published private(set) var assignments = [String: NativeMenuBarSection]()
    @Published private(set) var isHidden = false
    @Published private(set) var isAlwaysHidden = false
    @Published private(set) var isLoading = true
    @Published private(set) var message: String?
    @Published private(set) var isReordering = false
    @Published private(set) var orderingMessage: String?
    @Published private(set) var migrationMessage: String?

    private weak var appState: AppState?
    private let accessibility = MenuBarAccessibility()
    private let visibility = MenuBarVisibilityAssertion(
        activate: { bundles, completion in
            // Keep every supported Apple system item visible. In particular,
            // Clock and Control Center are never section members.
            ICENativeMenuBarActivate((0...8).map { NSNumber(value: $0) }, bundles, completion) as AnyObject?
        },
        invalidate: { ICENativeMenuBarInvalidate($0) }
    )
    private var statusItem: NSStatusItem?
    private var migrationBoundaries = [String: NSStatusItem]()
    private var migrationPositions = [String: CGFloat]()
    private var migrationTimeout: Task<Void, Never>?
    private var migrationCandidate: [String: NativeMenuBarSection]?
    private var migrationFrames = [CGRect]()
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var reorderTask: Task<Void, Never>?
    private var reorderOperation: NativeMenuBarOperation?
    private var observedOrder = [String]()
    private var needsVisibilitySync = false
    private var isRefreshing = false
    private var allowlist = NativeMenuBarAllowlist()
    private var items = [AccessibleMenuBarItem]()
    private var rehideTimer = NativeRehideTimer()
    private var hoverTimer = NativeRehideTimer()
    private var requestedVisibility = NativeMenuBarVisibilityRequest.visible
    private var generation = 0
    private var isTransitioning = false
    private var lastScroll: TimeInterval = 0
    private var menuIsTracking = false
    private var isSuspended = false
    private var dragWasActive = false
    private var hoveringOverEmptySpace = false
    private var hoverCheckPending = false
    private let logger = Logger(category: "NativeMenuBar")
    private static let assignmentsKey = "NativeMenuBarSectionsV1"
    private static let orderKey = "NativeMenuBarObservedOrderV1"

    init(appState: AppState) {
        self.appState = appState
    }

    private var general: GeneralSettingsManager? { appState?.settingsManager.generalSettingsManager }
    private var advanced: AdvancedSettingsManager? { appState?.settingsManager.advancedSettingsManager }

    func performSetup() {
        guard statusItem == nil else { return }
        observedOrder = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        if let saved = UserDefaults.standard.dictionary(forKey: Self.assignmentsKey) as? [String: String] {
            assignments = saved.compactMapValues(NativeMenuBarSection.init(rawValue:))
        } else {
            beginMigration()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "SItem.native.v1"
        item.button?.setAccessibilityIdentifier("Ice.Control")
        item.button?.setAccessibilityLabel("Ice")
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        updateConfiguration()

        appState?.settingsManager.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.updateConfiguration()
                self?.synchronizeVisibility()
            }
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
        NSWorkspace.shared.publisher(for: \.runningApplications)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.synchronizeVisibility()
                self?.refreshApplications()
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menuIsTracking = true }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in self?.menuIsTracking = false }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.shutdown() }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                isSuspended = true
                reorderTask?.cancel()
                generation += 1
                needsVisibilitySync = false
                isTransitioning = false
                visibility.restore()
                isHidden = false
                isAlwaysHidden = false
            }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isSuspended = false
                self?.synchronizeVisibility()
            }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.synchronizeVisibility() }
            .store(in: &subscriptions)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            for _ in 0..<5 where !migrationBoundaries.isEmpty {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                await refresh()
            }
            if !migrationBoundaries.isEmpty { abandonMigration() }
            guard !Task.isCancelled, !isSuspended else { return }
            setHidden(true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if appState?.navigationState.isSettingsPresented == true &&
                    appState?.navigationState.settingsNavigationIdentifier == .menuBarLayout {
                    await refresh()
                }
            }
        }
    }

    private func updateConfiguration() {
        guard let general else { return }
        if let item = statusItem, item.isVisible != general.showIceIcon {
            let name = item.autosaveName ?? "SItem.native.v1"
            let position: CGFloat? = StatusItemDefaults[.preferredPosition, name]
            item.isVisible = general.showIceIcon
            StatusItemDefaults[.preferredPosition, name] = position
        }
        updateImage()
        rehideTimer.reset()
    }

    private func updateImage() {
        guard let general, let appState else { return }
        statusItem?.button?.image = (isHidden ? general.iceIcon.hidden : general.iceIcon.visible).nsImage(for: appState)
        statusItem?.button?.toolTip = message ?? (isHidden ? "Show hidden menu bar items" : "Hide menu bar items")
    }

    func toggle(alwaysHidden: Bool = false) {
        setHidden(alwaysHidden ? !requestedVisibility.alwaysHidden : !requestedVisibility.hidden, alwaysHidden: alwaysHidden)
    }

    func setHidden(_ hidden: Bool, alwaysHidden: Bool = false) {
        requestedVisibility.setHidden(hidden, alwaysHidden: alwaysHidden,
                                      alwaysHiddenEnabled: advanced?.enableAlwaysHiddenSection == true)
        generation += 1
        isTransitioning = true
        rehideTimer.reset()
        synchronizeVisibility()
    }

    private func synchronizeVisibility() {
        guard statusItem != nil, !isSuspended, !isReordering else { return }
        if advanced?.enableAlwaysHiddenSection != true { requestedVisibility.alwaysHidden = false }
        let current = NativeMenuBarVisibilityRequest(hidden: isHidden, alwaysHidden: isAlwaysHidden)
        guard requestedVisibility.canApply(over: current, pressedMouseButtons: NSEvent.pressedMouseButtons) else {
            needsVisibilitySync = true
            visibility.cancelPending()
            return
        }
        needsVisibilitySync = false
        guard AXIsProcessTrusted(), ICENativeMenuBarAvailable() else {
            failOpen("Ice needs Accessibility permission and compatible native menu bar controls.")
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let hidden = NativeMenuBarPolicy.hiddenBundles(
            assignments: assignments, running: running, ownBundle: Constants.bundleIdentifier,
            hidden: requestedVisibility.hidden, alwaysHidden: requestedVisibility.alwaysHidden,
            alwaysHiddenEnabled: advanced?.enableAlwaysHiddenSection == true
        )
        let allowedBundles = allowlist.update(
            running: running,
            known: Set(assignments.keys).union(applications.map(\.id)).union([Constants.bundleIdentifier]),
            hidden: hidden
        )
        let desired: MenuBarVisibilityAssertion.Configuration? = hidden.isEmpty ? nil : .init(allowedBundles: allowedBundles)
        let targetHidden = requestedVisibility.hidden
        let targetAlwaysHidden = requestedVisibility.alwaysHidden && advanced?.enableAlwaysHiddenSection == true
        visibility.apply(desired) { [weak self] error in
            guard let self else { return }
            isTransitioning = false
            if let error {
                failOpen(error.localizedDescription)
            } else {
                let changed = isHidden != targetHidden || isAlwaysHidden != targetAlwaysHidden
                isHidden = targetHidden
                isAlwaysHidden = targetAlwaysHidden
                message = nil
                updateImage()
                if changed {
                    logger.info("Native visibility applied: hidden apps=\(hidden.count), hidden=\(isHidden), alwaysHidden=\(isAlwaysHidden)")
                }
            }
        }
    }

    private func failOpen(_ reason: String) {
        visibility.restore()
        requestedVisibility = .visible
        needsVisibilitySync = false
        isHidden = false
        isAlwaysHidden = false
        isTransitioning = false
        if message != reason { logger.warning(reason) }
        message = reason
        updateImage()
    }

    func refreshApplications() {
        Task { [weak self] in await self?.refresh() }
    }

    private func refresh() async {
        guard !isRefreshing, !isSuspended else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard AXIsProcessTrusted() else {
            failOpen("Accessibility permission is missing. All menu bar items are visible.")
            isLoading = false
            return
        }
        items = await accessibility.items(
            applications: NSWorkspace.shared.runningApplications,
            displays: NSScreen.screens.map { CGDisplayBounds($0.displayID) }
        )
        guard !Task.isCancelled else { return }
        var known = Dictionary(applications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            guard let bundle = item.bundleID, NativeMenuBarPolicy.canAssign(bundle, ownBundle: Constants.bundleIdentifier) else { continue }
            let app = NSRunningApplication(processIdentifier: item.ownerPID)
            let names = [app?.localizedName, item.title, app?.bundleURL?.deletingPathExtension().lastPathComponent, bundle]
            let title = names.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? bundle
            known[bundle] = NativeMenuBarApplication(id: bundle, title: title, ownerPID: item.ownerPID)
        }
        migrateIfReady(known: Set(known.keys))
        for bundle in assignments.keys where known[bundle] == nil {
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            let title = app?.localizedName ?? url?.deletingPathExtension().lastPathComponent ?? bundle
            known[bundle] = NativeMenuBarApplication(id: bundle, title: title, ownerPID: app?.processIdentifier ?? 0)
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        applications = known.values.filter { running.contains($0.id) || assignments[$0.id] != nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if let display = NSScreen.screens.first.map({ CGDisplayBounds($0.displayID) }) {
            let observed = items.filter {
                $0.isHosted && $0.isDrawn && display.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) &&
                    $0.frame.midY < display.minY + 48
            }.sorted { $0.frame.minX < $1.frame.minX }.compactMap(\.bundleID)
            observedOrder = NativeMenuBarOrder.reconcile(saved: observedOrder, observed: observed, known: applications.map(\.id))
            UserDefaults.standard.set(observedOrder, forKey: Self.orderKey)
            let ranks = Dictionary(uniqueKeysWithValues: observedOrder.enumerated().map { ($0.element, $0.offset) })
            applications.sort { ranks[$0.id, default: Int.max] < ranks[$1.id, default: Int.max] }
        }
        isLoading = false
        synchronizeVisibility()
    }

    private func beginMigration() {
        guard let hidden: CGFloat = StatusItemDefaults[.preferredPosition, "HItem"] else {
            saveAssignments() // Fresh install: no legacy section geometry to import.
            return
        }
        migrationPositions["HItem"] = hidden
        if advanced?.enableAlwaysHiddenSection == true,
           let always: CGFloat = StatusItemDefaults[.preferredPosition, "AHItem"] {
            migrationPositions["AHItem"] = always
        } else if advanced?.enableAlwaysHiddenSection == true {
            abandonMigration()
            return
        }
        for name in migrationPositions.keys.sorted() {
            let boundary = NSStatusBar.system.statusItem(withLength: 18)
            boundary.autosaveName = name
            boundary.button?.setAccessibilityIdentifier("Ice.MigrationBoundary.\(name)")
            migrationBoundaries[name] = boundary
        }
        migrationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.abandonMigration()
        }
    }

    private func migrateIfReady(known: Set<String>) {
        guard !migrationBoundaries.isEmpty, let screen = NSScreen.screens.first else { return }
        let display = CGDisplayBounds(screen.displayID)
        func sample(_ item: AccessibleMenuBarItem) -> NativeMenuBarMigration.Item {
            .init(frame: item.frame, trusted: item.isHosted && item.isDrawn)
        }
        func divider(_ name: String) -> NativeMenuBarMigration.Item? {
            items.first { $0.identifier == "Ice.MigrationBoundary.\(name)" }.map(sample)
        }
        guard let hidden = divider("HItem") else { migrationCandidate = nil; return }
        let always = divider("AHItem")
        let groups = Dictionary(grouping: items.filter { known.contains($0.bundleID ?? "") }, by: { $0.bundleID ?? "" })
        guard let candidate = NativeMenuBarMigration.assignments(
            apps: groups.mapValues { $0.map(sample) }, hidden: hidden, alwaysHidden: always,
            needsAlwaysHidden: migrationBoundaries["AHItem"] != nil, display: display
        ) else { migrationCandidate = nil; return }
        let frames = [hidden.frame] + (always.map { [$0.frame] } ?? [])
        // Require two matching snapshots, not a single transitional AX layout.
        guard migrationCandidate == candidate, migrationFrames == frames else {
            migrationCandidate = candidate
            migrationFrames = frames
            return
        }
        assignments.merge(candidate) { existing, _ in existing }
        saveAssignments()
        removeMigrationBoundary()
    }

    private func abandonMigration() {
        removeMigrationBoundary()
        saveAssignments()
        migrationMessage = "Ice could not reliably import the old sections. Apps without an assignment remain visible; arrange them here."
    }

    private func removeMigrationBoundary() {
        migrationTimeout?.cancel()
        migrationTimeout = nil
        for (name, boundary) in migrationBoundaries {
            NSStatusBar.system.removeStatusItem(boundary)
            StatusItemDefaults[.preferredPosition, name] = migrationPositions[name]
        }
        migrationBoundaries.removeAll()
        migrationPositions.removeAll()
        migrationCandidate = nil
        migrationFrames.removeAll()
    }

    func sectionItems(_ section: NativeMenuBarSection) -> [NativeMenuBarApplication] {
        applications.filter { (assignments[$0.id] ?? .visible) == section }
    }

    func move(_ application: NativeMenuBarApplication, to section: NativeMenuBarSection) {
        guard !isReordering, applications.contains(where: { $0.id == application.id }),
              NativeMenuBarPolicy.canAssign(application.id, ownBundle: Constants.bundleIdentifier) else { return }
        removeMigrationBoundary() // Explicit user choices supersede automatic import.
        assignments[application.id] = section
        if section == .alwaysHidden {
            advanced?.enableAlwaysHiddenSection = true
            if requestedVisibility.hidden { requestedVisibility.alwaysHidden = true }
        }
        saveAssignments()
        synchronizeVisibility()
    }

    /// A card drop is an explicit physical move, not a separate preferred order.
    func reorder(_ id: String, relativeTo target: NativeMenuBarApplication, before: Bool, section: NativeMenuBarSection) {
        guard !isReordering, id != target.id,
              let application = applications.first(where: { $0.id == id }),
              applications.contains(where: { $0.id == target.id }) else { return }
        if NativeMenuBarPolicy.sectionOnlyDrop(from: assignments[id] ?? .visible, to: section,
                                              sourceRunning: isRunning(application), targetRunning: isRunning(target)) {
            move(application, to: section)
            orderingMessage = "Section updated. Open both apps to change their physical order."
            return
        }
        guard isRunning(application), isRunning(target) else {
            orderingMessage = "Open both apps before changing their menu bar order."
            return
        }
        removeMigrationBoundary()
        isReordering = true
        orderingMessage = nil
        generation += 1
        rehideTimer.reset()
        let operation = NativeMenuBarOperation()
        reorderOperation = operation
        reorderTask = Task { [weak self] in
            guard let self else { return }
            let escape = UniversalEventMonitor.publisher(for: .keyDown).sink { [weak self] event in
                if event.keyCode == 53 { self?.cancelReorder() }
            }
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, reorderOperation === operation else { return }
                operation.stop(.timedOut)
                reorderTask?.cancel()
            }
            defer { escape.cancel(); deadline.cancel() }
            var failure: Error?
            do {
                // The settings drag must finish before borrowing the pointer.
                for _ in 0..<20 {
                    if inputIdle { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try operation.check()
                guard inputIdle, !isSuspended else { throw NativeMenuBarReorderer.Failure.busy }
                visibility.restore()
                isTransitioning = false
                isHidden = false
                isAlwaysHidden = false
                updateImage()
                try await Task.sleep(for: .milliseconds(600))
                try await NativeMenuBarReorderer.move(bundle: id, relativeTo: target.id, before: before, accessibility: accessibility, operation: operation)
                try operation.check()
                assignments[id] = section
                if section == .alwaysHidden {
                    advanced?.enableAlwaysHiddenSection = true
                    if requestedVisibility.hidden { requestedVisibility.alwaysHidden = true }
                }
                saveAssignments()
                logger.info("Native menu bar reorder verified")
            } catch { failure = operation.reason.map { $0 as Error } ?? error }
            deadline.cancel()
            escape.cancel()
            // Observe the expanded bar before restoring the user's hide state.
            // No queued preference can claim success for an unverified move.
            while isRefreshing && !isSuspended && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !isSuspended && !Task.isCancelled { await refresh() }
            isReordering = false
            reorderTask = nil
            reorderOperation = nil
            if !isSuspended && Task.isCancelled { refreshApplications() }
            synchronizeVisibility()
            if let failure, !(failure is CancellationError) {
                orderingMessage = failure.localizedDescription
                logger.warning("Native menu bar reorder failed: \(failure.localizedDescription)")
            }
            if !isSuspended, appState?.navigationState.isSettingsPresented == true {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func cancelReorder() {
        guard isReordering else { return }
        reorderOperation?.stop()
        reorderTask?.cancel()
    }

    func isRunning(_ application: NativeMenuBarApplication) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: application.id).contains { !$0.isTerminated }
    }

    func forget(_ application: NativeMenuBarApplication) {
        guard !isRunning(application) else { return }
        assignments.removeValue(forKey: application.id)
        applications.removeAll { $0.id == application.id }
        saveAssignments()
        synchronizeVisibility()
    }

    private func saveAssignments() {
        UserDefaults.standard.set(assignments.mapValues(\.rawValue), forKey: Self.assignmentsKey)
    }

    func shutdown() {
        generation += 1
        isSuspended = true
        isTransitioning = false
        needsVisibilitySync = false
        refreshTask?.cancel()
        reorderTask?.cancel()
        visibility.restore()
        removeMigrationBoundary()
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
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
    }

    private func scheduleRehide() {
        let request = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, generation == request, general?.autoRehide == true, !isHidden, !isTransitioning,
                  !isReordering, !pointerInMenuBar, inputIdle, !hasOpenMenu else { return }
            setHidden(true)
        }
    }

    private func tick() {
        guard !isSuspended, !isReordering else { return }
        if needsVisibilitySync && NSEvent.pressedMouseButtons == 0 { synchronizeVisibility() }
        let now = ProcessInfo.processInfo.systemUptime
        let dragging = NSEvent.modifierFlags.contains(.command) && NSEvent.pressedMouseButtons != 0 && pointerInMenuBar
        if dragging && !dragWasActive && advanced?.showAllSectionsOnUserDrag == true {
            setHidden(false, alwaysHidden: true)
        }
        if dragWasActive && !dragging {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                await self?.refresh()
            }
        }
        dragWasActive = dragging
        let allowed = general?.autoRehide == true && general?.rehideStrategy == .timed &&
            !isHidden && !isTransitioning && inputIdle && !pointerInMenuBar && !hasOpenMenu
        if rehideTimer.elapsed(now: now, interval: general?.rehideInterval ?? 0, allowed: allowed) {
            setHidden(true)
        }
        if general?.showOnHover == true && pointerInMenuBar && !hoverCheckPending {
            hoverCheckPending = true
            Task { [weak self] in
                guard let self else { return }
                hoveringOverEmptySpace = await emptyMenuBarPoint()
                hoverCheckPending = false
            }
        } else if !pointerInMenuBar { hoveringOverEmptySpace = false }
        if hoverTimer.elapsed(now: now, interval: advanced?.showOnHoverDelay ?? 0.2,
                              allowed: isHidden && !isTransitioning && general?.showOnHover == true && inputIdle && hoveringOverEmptySpace) {
            setHidden(false)
        }
    }

    private func emptyMenuBarPoint() async -> Bool {
        guard pointerInMenuBar, let top = NSScreen.screens.first?.frame.maxY else { return false }
        let point = CGPoint(x: NSEvent.mouseLocation.x, y: top - NSEvent.mouseLocation.y)
        return await accessibility.isEmptyMenuBar(at: point)
    }

    private func handle(_ event: NSEvent) {
        guard inputIdle, !isReordering else { return }
        switch event.type {
        case .leftMouseUp, .rightMouseUp:
            if !pointerInMenuBar && event.type == .leftMouseUp && general?.autoRehide == true && general?.rehideStrategy == .smart {
                scheduleRehide()
            } else if pointerInMenuBar {
                Task { [weak self] in
                    guard let self, await emptyMenuBarPoint(), inputIdle else { return }
                    if event.type == .leftMouseUp && general?.showOnClick == true { toggle() }
                    if event.type == .rightMouseUp && advanced?.showContextMenuOnRightClick == true { showMenu() }
                }
            }
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
        if let message {
            let warning = menu.addItem(withTitle: message, action: nil, keyEquivalent: "")
            warning.isEnabled = false
        }
        menu.addItem(.separator())
        let appearance = menu.addItem(withTitle: "Edit Menu Bar Appearance…", action: #selector(openAppearance), keyEquivalent: "")
        appearance.target = self
        let settings = menu.addItem(withTitle: "Ice Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let quit = menu.addItem(withTitle: "Quit Ice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func toggleFromMenu() { toggle() }
    @objc private func openAppearance() {
        appState?.appDelegate?.openSettingsWindow()
        appState?.navigationState.settingsNavigationIdentifier = .menuBarAppearance
    }
    @objc private func openSettings() { appState?.appDelegate?.openSettingsWindow() }
}
