import CoreGraphics
import Foundation

/// Reads input state without intercepting or suppressing events.
struct SleepInputSnapshot: Sendable {
    let idleTime: TimeInterval
    let hasHeldInput: Bool

    static func current() -> Self {
        let state = CGEventSourceStateID.combinedSessionState
        let idleTime = CGEventSource.secondsSinceLastEventType(
            state, eventType: CGEventType(rawValue: UInt32.max)!
        )
        let buttonsDown = (0..<32).contains {
            CGEventSource.buttonState(state, button: CGMouseButton(rawValue: UInt32($0))!)
        }
        // Caps Lock is a toggle, not a key the user must turn off to sleep.
        let keysDown = (0..<128).contains {
            $0 != 57 && CGEventSource.keyState(state, key: CGKeyCode($0))
        }
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let modifiersDown = !CGEventSource.flagsState(state).intersection(modifiers).isEmpty
        return Self(idleTime: idleTime, hasHeldInput: buttonsDown || keysDown || modifiersDown)
    }
}

/// A fixed delay can expire while the user is still moving away from the menu.
/// Require a full quiet interval, including after a held button/key is released.
/// A deadline prevents a forgotten request from sleeping a later interaction.
struct SleepInputSettler {
    static let quietInterval: TimeInterval = 1.2
    static let maximumWait: TimeInterval = 5

    enum Decision {
        case wait
        case ready
        case timedOut
    }

    let requestedAt: TimeInterval
    private var lastHeldInputAt: TimeInterval

    init(requestedAt: TimeInterval) {
        self.requestedAt = requestedAt
        self.lastHeldInputAt = requestedAt
    }

    mutating func decision(at now: TimeInterval, input: SleepInputSnapshot) -> Decision {
        if now - requestedAt >= Self.maximumWait { return .timedOut }
        if input.hasHeldInput {
            lastHeldInputAt = now
            return .wait
        }
        guard input.idleTime.isFinite, input.idleTime >= Self.quietInterval,
              now - lastHeldInputAt >= Self.quietInterval else { return .wait }
        return .ready
    }
}
