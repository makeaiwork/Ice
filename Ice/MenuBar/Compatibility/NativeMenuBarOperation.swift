//
//  NativeMenuBarOperation.swift
//  Ice
//

import Foundation

/// Shared cancellation/deadline state for one explicit rearrangement.
@MainActor
final class NativeMenuBarOperation {
    enum Stop: LocalizedError {
        case cancelled, timedOut

        var errorDescription: String? {
            switch self {
            case .cancelled: "Arrangement cancelled. Icons already moved keep their new positions."
            case .timedOut: "Arrangement stopped after 15 seconds. Icons already moved keep their new positions."
            }
        }
    }

    private(set) var reason: Stop?
    private let now: () -> TimeInterval
    private let deadline: TimeInterval

    init(limit: TimeInterval = 15, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        deadline = now() + limit
    }

    func stop(_ reason: Stop = .cancelled) {
        if self.reason == nil { self.reason = reason }
    }

    func check() throws {
        if reason == nil, now() >= deadline { stop(.timedOut) }
        if let reason { throw reason }
        try Task.checkCancellation()
    }
}
