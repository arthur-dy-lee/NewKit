import Foundation

/// The settings rows read left to right in the same order as menu bar items.
/// When expanded, the hidden section occupies the left side of the visible section.
enum MenuBarPhysicalOrder {
    static let dividerID = "\0NewKit.MenuBarOrganizer.Control\0"

    struct Move: Equatable {
        enum Target: Equatable {
            case app(String)
            case control
        }

        let sourceID: String
        let target: Target
        let placeAfter: Bool
    }

    static func displayedIDs(visible: [String], hidden: [String], expanded: Bool) -> [String] {
        (expanded ? hidden : []) + visible
    }

    /// Keep the reveal control between the two sections. It is a fixed menu
    /// bar item, so all moves use an app as their source. Checking only app
    /// order misses an icon that is on the wrong side of the control.
    static func movesToMatch(
        visible: [String], hidden: [String], expanded: Bool,
        positions: [String: CGFloat], dividerX: CGFloat
    ) -> [Move] {
        let availableHidden = (expanded ? hidden : []).filter { positions[$0] != nil }
        let availableVisible = visible.filter { positions[$0] != nil }
        let desiredX = availableHidden.compactMap { positions[$0] }
            + [dividerX] + availableVisible.compactMap { positions[$0] }
        guard !zip(desiredX, desiredX.dropFirst()).allSatisfy({ $0 < $1 }) else {
            return []
        }

        // Work outwards from the control. Each target has already reached its
        // correct side when the next move runs. The bridge skips pairs already
        // in order, and reads fresh coordinates for every physical move.
        var moves: [Move] = []
        for index in availableHidden.indices.reversed() {
            let target: Move.Target = index + 1 < availableHidden.count
                ? .app(availableHidden[index + 1]) : .control
            moves.append(Move(sourceID: availableHidden[index], target: target,
                              placeAfter: false))
        }
        for index in availableVisible.indices {
            let target: Move.Target = index > 0
                ? .app(availableVisible[index - 1]) : .control
            moves.append(Move(sourceID: availableVisible[index], target: target,
                              placeAfter: true))
        }
        return moves
    }

    /// A right-to-left insertion pass can restore any permutation while keeping
    /// the already ordered suffix in place. The native bridge skips pairs that
    /// already have the correct relative position.
    static func movesToMatch(_ desired: [String], positions: [String: CGFloat]) -> [(String, String)] {
        let available = desired.filter { positions[$0] != nil }
        guard available.count > 1 else { return [] }
        let alreadyOrdered = zip(available, available.dropFirst()).allSatisfy {
            positions[$0.0]! < positions[$0.1]!
        }
        guard !alreadyOrdered else { return [] }
        return (0..<(available.count - 1)).reversed().map {
            (available[$0], available[$0 + 1])
        }
    }
}
