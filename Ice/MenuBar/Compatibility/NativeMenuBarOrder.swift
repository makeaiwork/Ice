//
//  NativeMenuBarOrder.swift
//  Ice
//

import Foundation

/// The remembered order is observational, never a background command to move icons.
enum NativeMenuBarOrder {
    static func reconcile(saved: [String], observed: [String], known: [String]) -> [String] {
        let knownSet = Set(known)
        var seen = Set<String>()
        var result = (saved + known).filter { knownSet.contains($0) && seen.insert($0).inserted }
        seen = []
        let live = observed.filter { knownSet.contains($0) && seen.insert($0).inserted }
        let liveSet = Set(live)
        var iterator = live.makeIterator()
        for index in result.indices where liveSet.contains(result[index]) {
            if let next = iterator.next() { result[index] = next }
        }
        return result
    }

    /// All of one app's icons must land together, in their original internal order.
    static func isPlaced(_ moving: [String], relativeTo target: [String], before: Bool, in actual: [String]) -> Bool {
        guard !moving.isEmpty, !target.isEmpty,
              Set(moving).isDisjoint(with: target),
              let first = actual.firstIndex(of: moving[0]),
              first + moving.count <= actual.count,
              Array(actual[first..<(first + moving.count)]) == moving else { return false }
        if before {
            guard let anchor = actual.firstIndex(of: target[0]) else { return false }
            return first + moving.count == anchor
        }
        guard let last = target.last, let anchor = actual.firstIndex(of: last) else { return false }
        return first == anchor + 1
    }
}
