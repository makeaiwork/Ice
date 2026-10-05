//
//  NativeMenuBarPolicyTests.swift
//  Ice
//

import Foundation

@main
struct NativeMenuBarPolicyTests {
    static func main() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        expect(NativeMenuBarPolicy.hidingLength(anchorX: 1250, display: display, menuMaxX: 400, notch: nil) == 818, "finite spacer leaves overflow space")
        expect(NativeMenuBarPolicy.hidingLength(anchorX: 450, display: display, menuMaxX: 430, notch: nil) == nil, "refuse impossible spacer")
        expect(NativeMenuBarPolicy.hidingLength(anchorX: .nan, display: display, menuMaxX: 400, notch: nil) == nil, "reject invalid geometry")
        expect(NativeMenuBarPolicy.hidingLength(anchorX: 1600, display: display, menuMaxX: 400, notch: nil) == nil, "reject offscreen boundary")
        expect(NativeMenuBarPolicy.hidingLength(anchorX: 1200, display: display, menuMaxX: 100, notch: 700...812) == 568, "notch pushes spacer into left segment")
        expect(NativeMenuBarPolicy.hidingLength(anchorX: 1200, display: display, menuMaxX: 600, notch: 700...812) == 356, "small left segment uses right gap")
        let secondary = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        expect(NativeMenuBarPolicy.hidingLength(anchorX: -200, display: secondary, menuMaxX: -1500, notch: nil) == 1268, "secondary display uses global coordinates")
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
        print("20 native menu bar policy checks passed")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
