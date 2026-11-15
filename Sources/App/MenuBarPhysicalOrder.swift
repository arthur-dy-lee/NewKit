import Foundation

enum MenuBarPhysicalOrder {
    static let dividerID = "\0NewKit.MenuBarOrganizer.Control\0"

    struct Placement: Equatable {
        let source: String
        let target: String
        let after: Bool
    }

    struct Plan: Equatable {
        let visible: [String]
        let hidden: [String]
        let seatHidden: Bool
        let placement: Placement?

        var isEmpty: Bool { visible.isEmpty && hidden.isEmpty && placement == nil }

        /// The system stores distances from the right edge. Only assign new
        /// distances to the icons whose saved order or group needs restoring.
        func updates(
            positions: [String: Double], keys: [String: String]
        ) -> [String: Double] {
            var result = positions
            func restore(_ ids: [String]) {
                let items = ids.compactMap { keys[$0] }
                let slots = items.compactMap { result[$0] }.sorted(by: >)
                guard slots.count == items.count, Set(slots).count == slots.count else { return }
                for (key, slot) in zip(items, slots) { result[key] = slot }
            }
            restore(visible)
            if seatHidden, let divider = keys[MenuBarPhysicalOrder.dividerID],
               let anchor = result[divider] {
                let items = hidden.compactMap { keys[$0] }
                let itemKeys = Set(items)
                let boundary = positions.lazy.filter {
                    !itemKeys.contains($0.key) && $0.value > anchor
                }.map(\.value).min() ?? anchor + 64
                let spacing = (boundary - anchor) / Double(items.count + 1)
                for (index, key) in items.reversed().enumerated() {
                    result[key] = anchor + spacing * Double(index + 1)
                }
            } else {
                restore(hidden)
            }
            if let placement, let source = keys[placement.source],
               let target = keys[placement.target], let anchor = result[target] {
                let others = result.lazy.filter { $0.key != source }.map(\.value)
                let boundary = placement.after
                    ? others.filter { $0 < anchor }.max() ?? 0
                    : others.filter { $0 > anchor }.min() ?? anchor + 64
                result[source] = anchor + (boundary - anchor) / 2
            }
            return result.filter { positions[$0.key] != $0.value }
        }
    }

    /// Use the system's order as the starting point. Saved IDs take up only
    /// their own slots, including when a new status item appears between them.
    static func applyingSavedOrder(_ saved: [String], to system: [String]) -> [String] {
        let available = Set(system)
        let ordered = unique(saved).filter { available.contains($0) }
        let configured = Set(ordered)
        var slots = ordered.makeIterator()
        return system.map { configured.contains($0) ? slots.next() ?? $0 : $0 }
    }

    /// Keep saved positions for apps that are not currently in the settings list.
    static func savingOrder(_ displayed: [String], previous: [String], including: [String]) -> [String] {
        let saved = unique(previous + including)
        let configured = Set(saved)
        let arranged = displayed.filter { configured.contains($0) }
        let visible = Set(arranged)
        var slots = arranged.makeIterator()
        return saved.map { visible.contains($0) ? slots.next() ?? $0 : $0 }
    }

    static func plan(
        visible: [String], hidden: [String], saved: [String],
        positions: [String: CGFloat], placement: Placement?
    ) -> Plan {
        func observed(_ ids: [String]) -> [String] {
            ids.compactMap { id in positions[id].map { (id, $0) } }
                .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
                .map(\.0)
        }
        let systemVisible = observed(visible)
        let savedIDs = Set(saved)
        let configuredVisible = systemVisible.filter { savedIDs.contains($0) }
        let desiredVisible = applyingSavedOrder(saved, to: configuredVisible)
        let systemHidden = observed(hidden)
        let desiredHidden = applyingSavedOrder(saved, to: systemHidden)
        let seatHidden = positions[dividerID].map { divider in
            systemHidden.contains { (positions[$0] ?? divider) >= divider }
        } ?? false
        let pending = placement.flatMap { placement -> Placement? in
            for lane in [systemVisible, systemHidden] {
                guard let source = lane.firstIndex(of: placement.source),
                      let target = lane.firstIndex(of: placement.target) else { continue }
                let orderChanging = lane == systemVisible
                    ? configuredVisible != desiredVisible : systemHidden != desiredHidden || seatHidden
                let alreadyInPlace = source == target + (placement.after ? 1 : -1)
                return alreadyInPlace && !orderChanging ? nil : placement
            }
            return nil
        }
        return Plan(
            visible: configuredVisible == desiredVisible ? [] : desiredVisible,
            hidden: systemHidden == desiredHidden && !seatHidden ? [] : desiredHidden,
            seatHidden: seatHidden,
            placement: pending
        )
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
