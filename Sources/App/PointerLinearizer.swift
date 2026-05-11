import AppKit
import Foundation
import IOKit
import IOKit.hid

// MARK: - Private IOHIDEventSystemClient bridges
//
// Apple ships these symbols in `IOKit.framework` but does not expose headers.
// LinearMouse / Mac Mouse Fix use the same approach. They have been ABI-stable
// since at least macOS 10.13 — but if a future macOS retires them, the
// linearizer simply silently no-ops because every call is checked.

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary?)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientSetProperty")
private func IOHIDServiceClientSetProperty(_ service: AnyObject, _ key: CFString, _ value: AnyObject) -> Bool

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?

/// Disables Apple's pointer acceleration curve and rescales pointer
/// resolution for plugged-in mice — the LinearMouse / Mac Mouse Fix recipe.
/// Trackpads are intentionally left untouched (different match dict, and the
/// system's trackpad acceleration curve is part of the gesture experience).
///
/// The private-API surface is small and centralised here so the rest of the
/// app stays in public Swift.
@MainActor
final class PointerLinearizer {
    static let shared = PointerLinearizer()
    private init() {}

    /// IOHID property keys (string constants — they are not in any public
    /// header, but they're documented widely and have been stable for years).
    private static let kHIDPointerAcceleration: CFString = "HIDPointerAcceleration" as CFString
    private static let kHIDPointerResolution:   CFString = "HIDPointerResolution"   as CFString
    private static let kHIDMouseAcceleration:   CFString = "HIDMouseAcceleration"   as CFString
    private static let kRegistryEntryID:        CFString = "RegistryID"             as CFString

    /// Sentinel meaning "no acceleration" in IOHID's 16.16 fixed-point — the
    /// raw 32-bit integer `-1`. Apple's own slider sends this value at the
    /// far left of the tracking-speed range.
    private static let accelerationDisabled: Int32 = -65_536

    private var client: AnyObject?
    /// Saved per-mouse defaults (keyed by IOHID registry ID) so we can put the
    /// system back the way we found it when the user disables linearization.
    private var saved: [UInt64: SavedSettings] = [:]
    private var wakeObserver: NSObjectProtocol?

    private struct SavedSettings {
        let acceleration: Int32?
        let resolution:   Int32?
    }

    /// Pulls the current toggle state from `Configuration` and applies or
    /// reverts pointer settings to match. Safe to call repeatedly.
    func apply() {
        let on = Configuration.shared.linearPointerEnabled
        let mult = Configuration.shared.pointerSpeedMultiplier

        if !on {
            restoreAll()
            unobserveWake()
            return
        }

        guard let client = ensureClient() else {
            Log.error("PointerLinearizer: could not create IOHIDEventSystemClient — feature unavailable")
            return
        }
        applyToServices(in: client, multiplier: mult)
        observeWake()
    }

    private func ensureClient() -> AnyObject? {
        if let client { return client }
        guard let unmanaged = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return nil
        }
        let c = unmanaged.takeRetainedValue()

        // Match HID Generic Desktop / Mouse (page 1, usage 2). Trackpads
        // report as page 1 / usage 2 too on some Macs but only mouse-ish
        // services expose the acceleration property — non-mouse services
        // simply ignore the writes, so this is safe in practice.
        let match: [String: Any] = [
            "PrimaryUsagePage": kHIDPage_GenericDesktop,
            "PrimaryUsage":     kHIDUsage_GD_Mouse
        ]
        IOHIDEventSystemClientSetMatching(c, match as CFDictionary)
        client = c
        return c
    }

    private func applyToServices(in client: AnyObject, multiplier: Double) {
        guard let unmanaged = IOHIDEventSystemClientCopyServices(client) else {
            Log.info("PointerLinearizer: no matching HID services found")
            return
        }
        let services = unmanaged.takeRetainedValue() as [AnyObject]
        Log.info("PointerLinearizer: applying to \(services.count) mouse service(s) at multiplier=\(multiplier)")

        for service in services {
            let id = registryID(of: service)
            // Snapshot defaults once per service so toggling off restores
            // exactly what the user had configured in System Settings.
            if saved[id] == nil {
                saved[id] = SavedSettings(
                    acceleration: int32Property(service, key: Self.kHIDPointerAcceleration),
                    resolution:   int32Property(service, key: Self.kHIDPointerResolution)
                )
            }

            // 1. Disable acceleration curve.
            setInt32(service, key: Self.kHIDPointerAcceleration, value: Self.accelerationDisabled)
            // Some IOHID drivers respect the older "Mouse" key instead of
            // "Pointer". Writing both is harmless.
            setInt32(service, key: Self.kHIDMouseAcceleration, value: Self.accelerationDisabled)

            // 2. Scale resolution. resolution is counts-per-inch in 16.16
            // fixed-point — higher value = slower pointer per inch of
            // physical motion. Multiplier > 1 means "faster", so divide.
            if let baseline = saved[id]?.resolution, baseline > 0 {
                let scaled = Int32((Double(baseline) / max(0.1, multiplier)).rounded())
                setInt32(service, key: Self.kHIDPointerResolution, value: scaled)
            }
        }
    }

    private func restoreAll() {
        guard let client else { return }
        guard let unmanaged = IOHIDEventSystemClientCopyServices(client) else { return }
        let services = unmanaged.takeRetainedValue() as [AnyObject]
        for service in services {
            let id = registryID(of: service)
            guard let original = saved[id] else { continue }
            if let acc = original.acceleration {
                setInt32(service, key: Self.kHIDPointerAcceleration, value: acc)
                setInt32(service, key: Self.kHIDMouseAcceleration,   value: acc)
            }
            if let res = original.resolution {
                setInt32(service, key: Self.kHIDPointerResolution, value: res)
            }
        }
        saved.removeAll()
        Log.info("PointerLinearizer: restored pointer settings")
    }

    /// Re-apply on system wake — sleep can reset HID property writes on some
    /// chipsets, and freshly-attached mice are picked up here too.
    private func observeWake() {
        if wakeObserver != nil { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PointerLinearizer.shared.apply()
            }
        }
    }

    private func unobserveWake() {
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        wakeObserver = nil
    }

    // MARK: - IOHIDServiceClient property helpers

    private func setInt32(_ service: AnyObject, key: CFString, value: Int32) {
        var v = value
        let cf = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) as AnyObject
        _ = IOHIDServiceClientSetProperty(service, key, cf)
    }

    private func int32Property(_ service: AnyObject, key: CFString) -> Int32? {
        guard let unmanaged = IOHIDServiceClientCopyProperty(service, key) else { return nil }
        let value = unmanaged.takeRetainedValue()
        guard let num = value as? NSNumber else { return nil }
        return num.int32Value
    }

    private func registryID(of service: AnyObject) -> UInt64 {
        if let n = IOHIDServiceClientCopyProperty(service, Self.kRegistryEntryID)?
            .takeRetainedValue() as? NSNumber {
            return n.uint64Value
        }
        // hashValue is Int (signed) — direct UInt64 conversion crashes when
        // negative. truncatingIfNeeded reinterprets the bit pattern instead.
        return UInt64(truncatingIfNeeded: ObjectIdentifier(service).hashValue)
    }
}
