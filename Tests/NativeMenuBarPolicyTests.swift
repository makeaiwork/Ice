//
//  NativeMenuBarPolicyTests.swift
//  Ice
//

import Foundation

@main
struct NativeMenuBarPolicyTests {
    @MainActor private static var count = 0

    @MainActor
    static func main() async {
        let own = "com.jordanbaird.Ice"
        let assignments: [String: NativeMenuBarSection] = [
            "shown": .visible, "hidden": .hidden, "always": .alwaysHidden,
            own: .hidden, "com.apple.controlcenter": .hidden, "absent": .hidden,
        ]
        let running: Set<String> = ["shown", "hidden", "always", own, "com.apple.controlcenter", "new"]
        func hidden(_ hide: Bool, _ always: Bool, enabled: Bool = true) -> Set<String> {
            NativeMenuBarPolicy.hiddenBundles(assignments: assignments, running: running, ownBundle: own,
                                             hidden: hide, alwaysHidden: always, alwaysHiddenEnabled: enabled)
        }
        expect(hidden(true, true) == ["hidden", "always"], "hide both sections, protect own/system/unknown apps")
        expect(hidden(false, true) == ["always"], "show Hidden preserves Always-Hidden")
        expect(hidden(false, false).isEmpty, "Show All restores every app")
        expect(hidden(true, true, enabled: false) == ["hidden"], "disabled Always-Hidden remains visible")
        expect(hidden(true, false) == ["hidden"], "hidden section is independent")
        expect(!NativeMenuBarPolicy.canAssign("", ownBundle: own), "empty identity protected")
        expect(!NativeMenuBarPolicy.canAssign("com.apple.MenuBarAgent", ownBundle: own), "native host protected")
        expect(!NativeMenuBarPolicy.canAssign("com.apple.TextInputMenuAgent", ownBundle: own), "keyboard shared host protected")
        expect(NativeMenuBarPolicy.isInputIdle(buttons: 0, modifiers: 0), "idle input")
        expect(!NativeMenuBarPolicy.isInputIdle(buttons: 1, modifiers: 0), "held button blocks hiding")
        expect(!NativeMenuBarPolicy.isInputIdle(buttons: 0, modifiers: 1 << 20), "Command-drag blocks hiding")
        var timer = NativeRehideTimer()
        expect(!timer.elapsed(now: 1, interval: 2, allowed: true), "timer starts outside")
        expect(!timer.elapsed(now: 2.99, interval: 2, allowed: true), "timer respects interval")
        expect(timer.elapsed(now: 3, interval: 2, allowed: true), "timer fires at deadline")
        expect(!timer.elapsed(now: 4, interval: 2, allowed: false), "hover/menu/drag resets timer")
        expect(!timer.elapsed(now: 8, interval: 2, allowed: true), "resume starts new interval")
        expect(!timer.elapsed(now: 9, interval: 2, allowed: true), "no immediate rehide after interaction")
        expect(timer.elapsed(now: 10, interval: 2, allowed: true), "rehide after full new interval")
        expect(!timer.elapsed(now: 5, interval: 2, allowed: true), "clock rollback resets")
        expect(!timer.elapsed(now: .infinity, interval: 2, allowed: true), "invalid clock resets")
        expect(!timer.elapsed(now: 6, interval: -1, allowed: true), "invalid interval resets")
        testRequests()
        testOrder()
        await testOperation()
        testMigration()
        await testAssertions()
        await testTimeout()
        print("\(count) native menu bar checks passed")
    }

    @MainActor
    static func testOperation() async {
        var time: TimeInterval = 100
        let operation = NativeMenuBarOperation(now: { time })
        expect((try? operation.check()) != nil, "operation starts within its budget")
        time = 114.99
        expect((try? operation.check()) != nil, "operation may continue before deadline")
        time = 115
        expect((try? operation.check()) == nil && operation.reason == .timedOut, "deadline stops subsequent input")
        operation.stop(.cancelled)
        expect(operation.reason == .timedOut, "cleanup cancellation cannot overwrite timeout reason")
        let cancelled = NativeMenuBarOperation(now: { time })
        cancelled.stop()
        expect((try? cancelled.check()) == nil && cancelled.reason == .cancelled, "Esc and button cancellation stop input")
        let task = Task { @MainActor in
            let operation = NativeMenuBarOperation()
            withUnsafeCurrentTask { $0?.cancel() }
            return (try? operation.check()) == nil
        }
        let stopped = await task.value
        expect(stopped, "sleep or shutdown task cancellation also stops input")
        expect(NativeMenuBarPolicy.sectionOnlyDrop(from: .hidden, to: .visible, sourceRunning: false, targetRunning: true), "closed source can change section without a drag")
        expect(NativeMenuBarPolicy.sectionOnlyDrop(from: .visible, to: .alwaysHidden, sourceRunning: true, targetRunning: false), "closed target does not block section membership")
        expect(!NativeMenuBarPolicy.sectionOnlyDrop(from: .hidden, to: .visible, sourceRunning: true, targetRunning: true), "running apps retain physical placement between sections")
        expect(!NativeMenuBarPolicy.sectionOnlyDrop(from: .hidden, to: .hidden, sourceRunning: false, targetRunning: true), "closed app cannot pretend to change physical order")
    }

    @MainActor
    static func testMigration() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        func item(_ x: CGFloat, trusted: Bool = true) -> NativeMenuBarMigration.Item {
            .init(frame: CGRect(x: x, y: 0, width: 18, height: 24), trusted: trusted)
        }
        let groups = ["always": [item(100)], "hidden": [item(400)], "visible": [item(800)],
                      "mixed": [item(400), item(800)], "unknown": [item(100, trusted: false)]]
        func migrate(_ hidden: NativeMenuBarMigration.Item, _ always: NativeMenuBarMigration.Item?, needs: Bool = true) -> [String: NativeMenuBarSection]? {
            NativeMenuBarMigration.assignments(apps: groups, hidden: hidden, alwaysHidden: always, needsAlwaysHidden: needs, display: display)
        }
        let result = migrate(item(600), item(300))
        expect(result?["always"] == .alwaysHidden, "legacy Always-Hidden is retained")
        expect(result?["hidden"] == .hidden && result?["visible"] == .visible, "legacy Hidden and Visible classified separately")
        expect(result?["mixed"] == .visible, "multi-icon app straddling boundary remains visible")
        expect(result?["unknown"] == .visible, "stale or overflowed app geometry cannot hide it")
        expect(migrate(item(600, trusted: false), item(300)) == nil, "unhosted or overflowed divider cannot commit migration")
        expect(migrate(item(600), nil) == nil, "missing Always-Hidden divider does not downgrade its section")
        expect(migrate(item(600), item(700)) == nil, "inverted dividers rejected during layout reflow")
        expect(migrate(item(995), item(300)) == nil, "off-screen divider cannot commit migration")
        expect(migrate(item(600), nil, needs: false)?["always"] == .hidden, "disabled Always-Hidden needs only Hidden divider")
        let otherDisplay = NativeMenuBarMigration.Item(frame: CGRect(x: 600, y: 800, width: 18, height: 24), trusted: true)
        expect(migrate(otherDisplay, item(300)) == nil, "secondary display coordinates cannot classify primary icons")
    }

    @MainActor
    static func testOrder() {
        expect(NativeMenuBarOrder.reconcile(saved: [], observed: ["z", "b", "a"], known: ["a", "b", "z"]) == ["z", "b", "a"], "initial cards use physical order, not alphabet")
        expect(NativeMenuBarOrder.reconcile(saved: ["a", "hidden", "b"], observed: ["b", "a"], known: ["a", "b", "hidden"]) == ["b", "hidden", "a"], "hidden app keeps its remembered slot during partial refresh")
        expect(NativeMenuBarOrder.reconcile(saved: ["a", "b"], observed: ["new", "a", "b"], known: ["a", "b", "new"]) == ["new", "a", "b"], "new app follows observed relative order")
        expect(NativeMenuBarOrder.reconcile(saved: ["a", "gone", "a"], observed: ["b", "b", "unknown", "a"], known: ["a", "b"]) == ["b", "a"], "duplicates and stale identities cannot corrupt ranks")
        expect(NativeMenuBarOrder.isPlaced(["a1", "a2"], relativeTo: ["b"], before: true, in: ["x", "a1", "a2", "b"]), "group move preserves internal order before target")
        expect(NativeMenuBarOrder.isPlaced(["a1", "a2"], relativeTo: ["b1", "b2"], before: false, in: ["b1", "b2", "a1", "a2"]), "group can follow multi-icon target")
        expect(!NativeMenuBarOrder.isPlaced(["a1", "a2"], relativeTo: ["b"], before: true, in: ["a1", "x", "a2", "b"]), "split group is not reported as success")
        expect(!NativeMenuBarOrder.isPlaced(["a1", "a2"], relativeTo: ["b"], before: true, in: ["a2", "a1", "b"]), "reversed internal order is rejected")
        expect(!NativeMenuBarOrder.isPlaced(["a"], relativeTo: ["b"], before: true, in: ["a", "x", "b"]), "relative position alone does not verify insertion")
        expect(!NativeMenuBarOrder.isPlaced(["a"], relativeTo: ["b"], before: true, in: ["a"]), "missing target cannot verify a move")
    }

    @MainActor
    static func testRequests() {
        let shown = NativeMenuBarVisibilityRequest.visible
        let bothHidden = NativeMenuBarVisibilityRequest(hidden: true, alwaysHidden: true)
        var request = bothHidden
        request.setHidden(false, alwaysHidden: true, alwaysHiddenEnabled: true)
        expect(request == shown, "Command-drag requests both sections visible")
        expect(request.canApply(over: bothHidden, pressedMouseButtons: 1), "reveal is immediate during a held drag")
        request.setHidden(true, alwaysHidden: false, alwaysHiddenEnabled: true)
        expect(!request.canApply(over: shown, pressedMouseButtons: 1), "hide waits for mouse-up")
        for _ in 0..<100 { _ = request.canApply(over: shown, pressedMouseButtons: 1) }
        expect(request == bothHidden, "background refreshes never discard deferred intent")
        expect(!request.canApply(over: shown, pressedMouseButtons: 1), "background refresh cannot bypass held-mouse guard")
        expect(request.canApply(over: shown, pressedMouseButtons: 0), "hotkey modifiers do not block hiding")
        request.setHidden(false, alwaysHidden: false, alwaysHiddenEnabled: true)
        expect(request == .init(hidden: false, alwaysHidden: true), "reveal Hidden preserves Always-Hidden")
        request.setHidden(false, alwaysHidden: true, alwaysHiddenEnabled: true)
        expect(request == shown, "latest Show All replaces queued hide")
        expect(request.canApply(over: shown, pressedMouseButtons: 1), "Show All cancels even an unacknowledged hide during a drag")
        expect(!bothHidden.canApply(over: bothHidden, pressedMouseButtons: 1), "background allowlist changes wait during a drag")
        request.setHidden(true, alwaysHidden: false, alwaysHiddenEnabled: false)
        expect(!request.alwaysHidden, "disabled Always-Hidden cannot be requested")
        var allowlist = NativeMenuBarAllowlist()
        let first = allowlist.update(running: ["ice", "hidden", "unrelated"], known: ["saved", ""], hidden: ["hidden"])
        expect(first == ["ice", "saved", "unrelated"], "known saved apps retained; empty and hidden identities excluded")
        let afterExit = allowlist.update(running: ["ice", "hidden"], known: [], hidden: ["hidden"])
        expect(first == afterExit, "unrelated app exit does not replace assertion")
        let afterLaunch = allowlist.update(running: ["ice", "hidden", "new"], known: [], hidden: ["hidden"])
        expect(afterLaunch.contains("new") && !afterLaunch.contains("hidden"), "new recognized app allowed without revealing Hidden")
    }

    @MainActor
    static func testTimeout() async {
        var callback: ((Error?) -> Void)?
        let token = NSObject()
        var released = false
        var failures = 0
        let engine = MenuBarVisibilityAssertion(activate: { _, completion in
            callback = completion
            return token
        }, invalidate: { value in
            if value === token { released = true }
        }, activationTimeout: .milliseconds(20))
        engine.apply(.init(allowedBundles: ["ice"])) { if $0 != nil { failures += 1 } }
        try? await Task.sleep(for: .milliseconds(100))
        expect(released && failures == 1, "unacknowledged assertion times out and restores items")
        callback?(nil)
        await drain()
        expect(failures == 1, "late acknowledgement cannot revive timed-out assertion")
        released = false
        engine.apply(.init(allowedBundles: ["ice"])) { if $0 != nil { failures += 1 } }
        engine.restore()
        callback?(nil)
        try? await Task.sleep(for: .milliseconds(100))
        expect(released && failures == 1, "sleep/restore cancels pending activation and timeout")
    }

    @MainActor
    static func testAssertions() async {
        var callbacks = [(Error?) -> Void]()
        var tokens = [NSObject]()
        var invalidated = Set<ObjectIdentifier>()
        var unavailable = false
        let engine = MenuBarVisibilityAssertion(activate: { _, callback in
            guard !unavailable else { return nil }
            let token = NSObject()
            tokens.append(token)
            callbacks.append(callback)
            return token
        }, invalidate: { token in
            if let token { invalidated.insert(ObjectIdentifier(token)) }
        })
        let first = MenuBarVisibilityAssertion.Configuration(allowedBundles: ["ice", "visible"])
        let second = MenuBarVisibilityAssertion.Configuration(allowedBundles: ["ice"])
        let third = MenuBarVisibilityAssertion.Configuration(allowedBundles: ["ice", "another"])
        var successes = 0
        var failures = 0
        let completion: (Error?) -> Void = { if $0 == nil { successes += 1 } else { failures += 1 } }
        engine.apply(first, completion: completion)
        expect(tokens.count == 1 && successes == 0, "wait for activation acknowledgement")
        callbacks[0](nil)
        await drain()
        expect(successes == 1 && invalidated.isEmpty, "first assertion stays alive")
        engine.apply(first, completion: completion)
        expect(tokens.count == 1 && successes == 2, "unchanged configuration is not reactivated")
        engine.apply(second, completion: completion)
        expect(!invalidated.contains(ObjectIdentifier(tokens[0])), "retain current assertion during replacement")
        engine.apply(third, completion: completion)
        expect(invalidated.contains(ObjectIdentifier(tokens[1])), "superseded pending assertion is released")
        callbacks[1](NSError(domain: "test", code: 1))
        await drain()
        expect(failures == 0 && !invalidated.contains(ObjectIdentifier(tokens[0])), "stale failure cannot reveal current section")
        callbacks[2](nil)
        await drain()
        expect(successes == 3 && invalidated.contains(ObjectIdentifier(tokens[0])), "successful handover releases predecessor")
        expect(!invalidated.contains(ObjectIdentifier(tokens[2])), "successor remains active")
        engine.restore()
        expect(invalidated.contains(ObjectIdentifier(tokens[2])), "restore/quit releases active assertion")
        callbacks[2](NSError(domain: "test", code: 2))
        await drain()
        expect(failures == 0, "late callback after restore ignored")
        engine.apply(first, completion: completion)
        callbacks[3](NSError(domain: "test", code: 3))
        await drain()
        expect(failures == 1 && invalidated.contains(ObjectIdentifier(tokens[3])), "activation failure fails open")
        engine.apply(first, completion: completion)
        callbacks[4](nil)
        await drain()
        engine.apply(second, completion: completion)
        engine.cancelPending()
        expect(invalidated.contains(ObjectIdentifier(tokens[5])) && !invalidated.contains(ObjectIdentifier(tokens[4])), "cancel pending preserves acknowledged assertion")
        callbacks[5](nil)
        await drain()
        expect(successes == 4, "superseded pending callback cannot publish old visibility")
        engine.apply(first, completion: completion)
        expect(tokens.count == 6 && successes == 5, "cancel restores acknowledged configuration without reactivation")
        unavailable = true
        engine.apply(second, completion: completion)
        expect(failures == 2, "missing native API fails open synchronously")
        engine.apply(nil, completion: completion)
        expect(successes == 6, "empty hide set restores without assertion")
    }

    @MainActor
    static func drain() async { try? await Task.sleep(for: .milliseconds(5)) }

    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        count += 1
    }
}
