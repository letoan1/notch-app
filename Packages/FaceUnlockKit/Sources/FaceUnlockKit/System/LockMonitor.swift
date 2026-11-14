//
//  LockMonitor.swift
//  FaceUnlockKit
//
//  Adapted from Glance (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance
//  See LICENSES/Glance-MIT.txt.
//
//  Detects macOS lock/unlock/sleep/wake signals.
//  Port note: `@Observable` + `withObservationTracking` → `ObservableObject` + an `onEvent` callback.
//

import Foundation
import AppKit
import CoreGraphics
import Combine

/// Which signal most recently fired.
public enum LockEventKind: Sendable {
    case screenLocked
    case screenUnlocked
    case willSleep
    /// Display turned back on, from system sleep, display sleep, or the screensaver stopping.
    case wake
}

@MainActor
final class LockMonitor: ObservableObject {
    /// NOT trustworthy alone: any same-user process can post these distributed notifications, and this process can be
    /// suspended before one is delivered. UI/trigger signal only, never a security gate — use `isScreenActuallyLocked()`.
    @Published private(set) var isScreenLocked: Bool = false

    /// True from `willSleepNotification` until the next wake. `screenIsLocked` fires ~150ms before the system actually
    /// finishes suspending, so callers should skip acting on a lock while this is true and wait for the wake trigger.
    @Published private(set) var isSleeping: Bool = false

    @Published private(set) var lastEvent: LockEventKind?

    /// Fired on the main queue for every event, including repeats of the same kind.
    var onEvent: ((LockEventKind) -> Void)?

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        isScreenLocked = Self.isScreenActuallyLocked()
        startMonitoring()
    }

    deinit {
        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributed.removeObserver(observer)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
    }

    private func startMonitoring() {
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isScreenLocked = true
                self?.record(.screenLocked)
            }
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isScreenLocked = false
                self?.record(.screenUnlocked)
            }
        })
        // Observing the key press that dismissed the screensaver isn't possible — Secure Event Input suppresses keyboard
        // taps on the lock screen regardless of Accessibility trust — so this notification stands in for it.
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.record(.wake)
            }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSleeping = true
                self?.record(.willSleep)
            }
        })
        // Display- and system-level wake are treated as equivalent triggers — they land within ~100ms of each other.
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordWake() }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordWake() }
        })
    }

    private func recordWake() {
        isSleeping = false
        record(.wake)
    }

    private func record(_ kind: LockEventKind) {
        lastEvent = kind
        onEvent?(kind)
    }

    /// Authoritative lock state from the CoreGraphics session server, not a spoofable notification. Fails closed if
    /// unavailable (returns false → nothing is typed).
    nonisolated static func isScreenActuallyLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
