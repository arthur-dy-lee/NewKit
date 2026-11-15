import Foundation

@main
enum MenuBarPhysicalOrderChecks {
    static func main() {
        let divider = MenuBarPhysicalOrder.dividerID
        let physical = ["New", "B", "Other", "A", "C"]
        assert(MenuBarPhysicalOrder.applyingSavedOrder(["A", "B"], to: physical)
               == ["New", "A", "Other", "B", "C"])
        assert(MenuBarPhysicalOrder.applyingSavedOrder(["Z", "A", "A", "B"], to: physical)
               == ["New", "A", "Other", "B", "C"])
        assert(MenuBarPhysicalOrder.savingOrder(["B", "New", "A", "C"],
            previous: ["A", "Offline", "B"], including: ["New", "A"])
            == ["B", "Offline", "New", "A"])

        let current = ["New": 900.0, "B": 800, "Other": 700, "A": 600, "C": 500, divider: 1_000]
        let plan = makePlan(physical, saved: ["A", "B"], using: current)
        assert(plan.updates(positions: current, keys: identity(current)) == ["A": 800, "B": 600])
        assert(makePlan(["A", "B", "New"], saved: ["A", "B"], using: current, physical: [
            "A": 0, "New": 1, "B": 2
        ]).isEmpty, "A new icon in the middle of an ordered lane must not trigger a write")
        assert(makePlan(physical, saved: [], using: current).isEmpty)

        let order = MenuBarPhysicalOrder.Placement(source: "New", target: "B", after: true)
        let placement = makePlan(physical, saved: ["B", "New"], using: current, placement: order)
        let rearranged = current.merging(placement.updates(
            positions: current, keys: identity(current)
        ), uniquingKeysWith: { _, new in new })
        assert(rearranged["B"]! > rearranged["New"]! && rearranged["New"]! > rearranged["Other"]!)
        assert(rearranged["Other"] == current["Other"])

        let hidden = ["H2", "H1"]
        let expanded = [divider: 800.0, "H1": 950, "H2": 400, "New": 850, "Other": 500]
        let expandedPlan = makePlan(["New", "Other"], hidden: hidden, saved: ["H1", "H2"], using: expanded)
        let changes = expandedPlan.updates(positions: expanded, keys: identity(expanded))
        assert(changes["H1"]! > changes["H2"]! && changes["H2"]! > expanded[divider]!)
        assert(changes["H1"]! < expanded["New"]!)
        assert(Set(changes.keys) == Set(hidden), "Grouping must not move visible icons or the divider")
        assert(makePlan(["New", "Other"], saved: hidden, using: expanded).isEmpty)

        let ambiguous = ["B": "B", "New": "New"]
        assert(plan.updates(positions: current, keys: ambiguous).isEmpty)
        assert(plan.updates(positions: ["A": 600, "B": 600], keys: identity(current)).isEmpty)
        print("Menu bar order checks passed")
    }

    private static func identity(_ positions: [String: Double]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: positions.keys.map { ($0, $0) })
    }

    private static func makePlan(
        _ visible: [String], hidden: [String] = [], saved: [String],
        using positions: [String: Double], physical: [String: CGFloat]? = nil,
        placement: MenuBarPhysicalOrder.Placement? = nil
    ) -> MenuBarPhysicalOrder.Plan {
        MenuBarPhysicalOrder.plan(visible: visible, hidden: hidden, saved: saved, positions:
            physical ?? positions.mapValues { CGFloat(-$0) }, placement: placement)
    }
}
