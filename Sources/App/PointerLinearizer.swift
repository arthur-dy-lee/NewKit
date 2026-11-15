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
    private struct SavedSettings {
        var acceleration: PointerPropertyLease?
        var mouseAcceleration: PointerPropertyLease?
        var resolution: PointerPropertyLease?
    }

    /// Pulls the current toggle state from `Configuration` and applies or
    /// reverts pointer settings to match. Safe to call repeatedly.
    func apply(suspended: Bool) {
        let on = !suspended && Configuration.shared.linearPointerEnabled
        let mult = Configuration.shared.pointerSpeedMultiplier

        if !on {
            restoreAll()
            return
        }

        guard let client = ensureClient() else {
            Log.error("PointerLinearizer: could not create IOHIDEventSystemClient — feature unavailable")
            return
        }
        applyToServices(in: client, multiplier: mult)
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
            var original = saved[id] ?? SavedSettings()
            let baseline = original.resolution?.originalValue
                ?? int32Property(service, key: Self.kHIDPointerResolution)

            // 1. Disable acceleration curve.
            applyOwnedProperty(service, key: Self.kHIDPointerAcceleration,
                               value: Self.accelerationDisabled, lease: &original.acceleration)
            // Some IOHID drivers respect the older "Mouse" key instead of
            // "Pointer". Writing both is harmless.
            applyOwnedProperty(service, key: Self.kHIDMouseAcceleration,
                               value: Self.accelerationDisabled, lease: &original.mouseAcceleration)

            // 2. Scale resolution. resolution is counts-per-inch in 16.16
            // fixed-point — higher value = slower pointer per inch of
            // physical motion. Multiplier > 1 means "faster", so divide.
            if let baseline, baseline > 0 {
                let scaled = Int32(min(Double(Int32.max),
                                       (Double(baseline) / max(0.1, multiplier)).rounded()))
                applyOwnedProperty(service, key: Self.kHIDPointerResolution,
                                   value: scaled, lease: &original.resolution)
            }
            saved[id] = original
        }
    }

    private func restoreAll() {
        guard !saved.isEmpty else { return }
        let owned = saved
        // End ownership even if a device has disappeared. An old snapshot
        // must never be replayed later while Smooze is managing the mouse.
        saved.removeAll()
        guard let client else { return }
        guard let unmanaged = IOHIDEventSystemClientCopyServices(client) else { return }
        let services = unmanaged.takeRetainedValue() as [AnyObject]
        for service in services {
            let id = registryID(of: service)
            guard let original = owned[id] else { continue }
            restoreOwnedProperty(service, key: Self.kHIDPointerAcceleration, lease: original.acceleration)
            restoreOwnedProperty(service, key: Self.kHIDMouseAcceleration, lease: original.mouseAcceleration)
            restoreOwnedProperty(service, key: Self.kHIDPointerResolution, lease: original.resolution)
        }
        Log.info("PointerLinearizer: released NK pointer settings without overwriting later changes")
    }

    private func applyOwnedProperty(_ service: AnyObject, key: CFString,
                                    value: Int32, lease: inout PointerPropertyLease?) {
        guard let current = int32Property(service, key: key) else { return }
        var owned = lease ?? PointerPropertyLease(originalValue: current)
        if setInt32(service, key: key, value: value) {
            owned.didApply(value)
            lease = owned
        }
    }

    private func restoreOwnedProperty(_ service: AnyObject, key: CFString,
                                      lease: PointerPropertyLease?) {
        guard let lease else { return }
        if let original = lease.valueToRestore(currentValue: int32Property(service, key: key)) {
            _ = setInt32(service, key: key, value: original)
        } else {
            Log.info("PointerLinearizer: preserving external change to \(key)")
        }
    }

    // MARK: - IOHIDServiceClient property helpers

    @discardableResult
    private func setInt32(_ service: AnyObject, key: CFString, value: Int32) -> Bool {
        var v = value
        let cf = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) as AnyObject
        let applied = IOHIDServiceClientSetProperty(service, key, cf)
        if !applied { Log.error("PointerLinearizer: could not set \(key)") }
        return applied
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
