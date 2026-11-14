//
//  LockScreenWindowHelper.swift
//  FaceUnlockKit
//
//  Adapted from Glance's NotchOverlay/NotchSkyLight.swift (MIT) by Jonathan Zhou — https://github.com/jonnyoo/glance —
//  which is itself adapted from Lakr233/SkyLightWindow (MIT) — https://github.com/Lakr233/SkyLightWindow.
//  See LICENSES/Glance-MIT.txt and LICENSES/SkyLightWindow-MIT.txt.
//
//  Private, undocumented SkyLight window-server API — the only known way to make a window visible on the real
//  macOS lock screen.
//
//  RISK: dlopen's a private Apple framework and calls undocumented C symbols. Apple can change or remove them in any
//  macOS update, and their use disqualifies Mac App Store distribution. If loading fails every call is a no-op that
//  returns false, so the host degrades to "no lock-screen visibility" instead of crashing.
//
//  Side effect: the first successful `moveToLockScreen` creates one SkyLight space (level 400) for the process
//  lifetime. `isAvailable` only dlopen/dlsym's the symbols.
//

import AppKit

@MainActor
public enum LockScreenWindowHelper {
    /// Whether the private SkyLight symbols resolved on this macOS version (loads them on first call).
    public static var isAvailable: Bool { SkyLightBridge.shared != nil }

    /// Moves `window` into an elevated SkyLight space so it renders above the lock screen.
    /// Only acts while the session server reports the screen actually locked; returns whether it was moved.
    /// The window should already be ordered in (e.g. `orderFrontRegardless()`), since it needs a window number.
    @discardableResult
    public static func moveToLockScreen(_ window: NSWindow) -> Bool {
        guard LockMonitor.isScreenActuallyLocked(), window.windowNumber > 0,
              let bridge = SkyLightBridge.shared else { return false }
        bridge.delegate(window)
        return true
    }

    /// Returns `window` to normal window-server behavior. Call as soon as the screen unlocks (or before closing it).
    public static func restoreFromLockScreen(_ window: NSWindow) {
        guard window.windowNumber > 0, let bridge = SkyLightBridge.shared else { return }
        bridge.undelegate(window)
    }
}

/// What Notification Center itself renders at while the screen is locked.
private enum SkyLightSpaceLevel: Int32 {
    case notificationCenterAtScreenLock = 400
}

@MainActor
private final class SkyLightBridge {
    /// `nil` if the private framework or any symbol couldn't be loaded.
    static let shared: SkyLightBridge? = SkyLightBridge()

    private let connection: Int32
    /// Created on first `delegate`, not at symbol-load time, so `isAvailable` has no window-server side effects.
    private var space: Int32?

    private typealias F_SLSMainConnectionID = @convention(c) () -> Int32
    private typealias F_SLSSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let spaceCreate: F_SLSSpaceCreate
    private let setAbsoluteLevel: F_SLSSpaceSetAbsoluteLevel
    private let showSpaces: F_SLSShowSpaces
    private let addWindowsAndRemoveFromSpaces: F_SLSSpaceAddWindowsAndRemoveFromSpaces
    private let removeWindowsFromSpaces: F_SLSRemoveWindowsFromSpaces

    private init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW
        ) else { return nil }

        guard
            let mainConnectionSym = dlsym(handle, "SLSMainConnectionID"),
            let spaceCreateSym = dlsym(handle, "SLSSpaceCreate"),
            let setLevelSym = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
            let showSpacesSym = dlsym(handle, "SLSShowSpaces"),
            let addRemoveSym = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
            let removeSym = dlsym(handle, "SLSRemoveWindowsFromSpaces")
        else { return nil }

        let mainConnectionID = unsafeBitCast(mainConnectionSym, to: F_SLSMainConnectionID.self)
        spaceCreate = unsafeBitCast(spaceCreateSym, to: F_SLSSpaceCreate.self)
        setAbsoluteLevel = unsafeBitCast(setLevelSym, to: F_SLSSpaceSetAbsoluteLevel.self)
        showSpaces = unsafeBitCast(showSpacesSym, to: F_SLSShowSpaces.self)
        addWindowsAndRemoveFromSpaces = unsafeBitCast(addRemoveSym, to: F_SLSSpaceAddWindowsAndRemoveFromSpaces.self)
        removeWindowsFromSpaces = unsafeBitCast(removeSym, to: F_SLSRemoveWindowsFromSpaces.self)

        connection = mainConnectionID()
    }

    private func elevatedSpace() -> Int32 {
        if let space { return space }
        // The `1` flag is load-bearing: any other value causes Finder to draw desktop icons into this space.
        let created = spaceCreate(connection, 1, 0)
        _ = setAbsoluteLevel(connection, created, SkyLightSpaceLevel.notificationCenterAtScreenLock.rawValue)
        _ = showSpaces(connection, [created] as CFArray)
        space = created
        return created
    }

    func delegate(_ window: NSWindow) {
        _ = addWindowsAndRemoveFromSpaces(connection, elevatedSpace(), [window.windowNumber] as CFArray, 7)
    }

    func undelegate(_ window: NSWindow) {
        guard let space else { return }
        _ = removeWindowsFromSpaces(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}
