//
//  SessionAutoLocker.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  Re-locks the Touch-ID session once idle past the configured limit.
//  Port note: reads the limit from a closure instead of GlanceSettings, and reports via `onDidLock`
//  instead of routing through Glance's POCController.
//

import Foundation
import AppKit

@MainActor
final class SessionAutoLocker {
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let idleLimitProvider: () -> TimeInterval?
    var onDidLock: (() -> Void)?

    /// Coarse on purpose — the decision compares timestamps, not ticks.
    private let checkInterval: TimeInterval

    init(checkInterval: TimeInterval = 5 * 60, idleLimitProvider: @escaping () -> TimeInterval?) {
        self.checkInterval = checkInterval
        self.idleLimitProvider = idleLimitProvider
        // `.common` so the countdown keeps being checked during tracking runloop modes (an open menu, a drag).
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Also evaluate on wake: no timer fires during sleep, but the elapsed time still counts as idle once compared.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }

        evaluate()
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func evaluate() {
        guard SecureCredentialManager.isSessionUnlocked,
              let lastActivityAt = SecureCredentialManager.lastActivityAt
        else { return }

        // `nil` ("never") still loses the in-memory session key on app relaunch.
        guard let idleLimit = idleLimitProvider() else { return }
        guard Date().timeIntervalSince(lastActivityAt) >= idleLimit else { return }

        SecureCredentialManager.lockSession()
        onDidLock?()
    }
}
