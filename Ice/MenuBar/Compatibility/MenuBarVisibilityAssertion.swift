//
//  MenuBarVisibilityAssertion.swift
//  Ice
//

import Foundation

/// Replaces a native menu-bar visibility assertion only after its successor
/// activates. Errors, timeout and explicit restoration release every assertion.
@MainActor
final class MenuBarVisibilityAssertion {
    struct Configuration: Equatable {
        let allowedBundles: [String]
    }

    private var current: AnyObject?
    private var pending: AnyObject?
    private var configuration: Configuration?
    private var currentConfiguration: Configuration?
    private var generation = 0
    private var timeout: Task<Void, Never>?
    private var pendingCompletion: ((Error?) -> Void)?
    private let activate: ([String], @escaping (Error?) -> Void) -> AnyObject?
    private let invalidate: (AnyObject?) -> Void
    private let activationTimeout: Duration

    init(
        activate: @escaping ([String], @escaping (Error?) -> Void) -> AnyObject?,
        invalidate: @escaping (AnyObject?) -> Void,
        activationTimeout: Duration = .seconds(5)
    ) {
        self.activate = activate
        self.invalidate = invalidate
        self.activationTimeout = activationTimeout
    }

    func apply(_ desired: Configuration?, completion: @escaping (Error?) -> Void) {
        guard desired != configuration else {
            if pending != nil { pendingCompletion = completion } else { completion(nil) }
            return
        }
        guard let desired else {
            restore()
            completion(nil)
            return
        }
        generation += 1
        let request = generation
        timeout?.cancel()
        invalidate(pending)
        pending = nil
        configuration = desired
        pendingCompletion = completion
        pending = activate(desired.allowedBundles) { [weak self] error in
            Task { @MainActor in self?.finish(request: request, error: error) }
        }
        guard pending != nil else {
            finish(request: request, error: Self.error("Native menu bar controls are unavailable."))
            return
        }
        let activationTimeout = activationTimeout
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: activationTimeout) } catch { return }
            self?.finish(request: request, error: Self.error("macOS did not confirm the menu bar change."))
        }
    }

    private func finish(request: Int, error: Error?) {
        guard generation == request, pendingCompletion != nil else { return }
        let completion = pendingCompletion
        pendingCompletion = nil
        timeout?.cancel()
        timeout = nil
        if error != nil {
            restore()
        } else {
            invalidate(current)
            current = pending
            currentConfiguration = configuration
            pending = nil
        }
        completion?(error)
    }

    /// Cancels a superseded in-flight change while preserving the last
    /// acknowledged visibility. Cancelled callbacks deliberately do not fire.
    func cancelPending() {
        guard pending != nil else { return }
        generation += 1
        timeout?.cancel()
        timeout = nil
        invalidate(pending)
        pending = nil
        configuration = currentConfiguration
        pendingCompletion = nil
    }

    func restore() {
        generation += 1
        timeout?.cancel()
        timeout = nil
        invalidate(current)
        invalidate(pending)
        current = nil
        pending = nil
        configuration = nil
        currentConfiguration = nil
        pendingCompletion = nil
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "Ice.NativeMenuBar", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
