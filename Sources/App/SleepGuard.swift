import Foundation
import IOKit.pwr_mgt

/// Holds an `IOPMAssertion` so the system (and optionally the display) does not
/// go to idle sleep while NewKit's "Keep Awake" toggle is on. Equivalent to
/// `caffeinate -i` (or `caffeinate -di` when the display option is also on).
///
/// Switching between display/system-only flavors recreates the assertion under
/// the new type — IOPMAssertion has no in-place upgrade.
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()
    private init() {}

    private var assertionID: IOPMAssertionID = 0
    private var heldType: CFString?

    /// Pulls the current toggle state from `Configuration` and creates/releases
    /// the assertion to match. Safe to call repeatedly.
    func apply() {
        let want = Configuration.shared.preventSleep
        let alsoDisplay = Configuration.shared.preventDisplaySleep

        if !want {
            release()
            return
        }

        let desiredType = alsoDisplay
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
            : kIOPMAssertionTypePreventUserIdleSystemSleep as CFString

        if heldType == desiredType { return }
        release()
        acquire(type: desiredType)
    }

    private func acquire(type: CFString) {
        var id: IOPMAssertionID = 0
        let reason = "NewKit – Keep Awake" as CFString
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            heldType = type
        } else {
            Log.error("SleepGuard: IOPMAssertionCreate failed (\(result))")
        }
    }

    private func release() {
        guard heldType != nil else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        heldType = nil
    }
}
