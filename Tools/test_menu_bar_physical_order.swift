import Foundation

@main
enum MenuBarPhysicalOrderChecks {
    static func main() {
        let visible = ["A", "B", "C"]
        let hidden = ["H1", "H2"]

        check(desired: ["C", "A", "B"], actual: visible)
        let expanded = MenuBarPhysicalOrder.displayedIDs(
            visible: visible, hidden: hidden, expanded: true
        )
        assert(expanded == ["H1", "H2", "A", "B", "C"])
        check(desired: expanded, actual: ["A", "H2", "B", "H1", "C"])
        let collapsed = MenuBarPhysicalOrder.displayedIDs(
            visible: visible, hidden: hidden, expanded: false
        )
        assert(collapsed == visible)
        check(desired: collapsed, actual: visible)

        // Every five-icon permutation converges, including cases where a pair
        // starts in order but is displaced by an earlier insertion.
        for actual in permutations(["A", "B", "C", "D", "E"]) {
            check(desired: ["A", "B", "C", "D", "E"], actual: actual)
        }

        // Docker can be to ChatGPT's right but still on the wrong side of the
        // reveal control. The app-only order is correct in this case.
        checkWithControl(
            visible: ["Visible"], hidden: ["ChatGPT", "Docker"],
            actual: ["ChatGPT", "<", "Docker", "Visible"]
        )
        for actual in permutations(["H1", "H2", "H3", "<", "V1", "V2"]) {
            checkWithControl(
                visible: ["V1", "V2"], hidden: ["H1", "H2", "H3"],
                actual: actual
            )
        }
        for actual in permutations(["<", "V1", "V2", "V3"]) {
            checkWithControl(visible: ["V1", "V2", "V3"], hidden: ["H1"],
                             actual: actual, expanded: false)
        }
        print("Menu bar physical order checks passed")
    }

    private static func check(desired: [String], actual: [String]) {
        let positions = Dictionary(uniqueKeysWithValues: actual.enumerated().map {
            ($0.element, CGFloat($0.offset))
        })
        let moves = MenuBarPhysicalOrder.movesToMatch(desired, positions: positions)
        var result = actual
        for (source, target) in moves {
            let sourceIndex = result.firstIndex(of: source)!
            let targetIndex = result.firstIndex(of: target)!
            guard sourceIndex > targetIndex else { continue }
            result.remove(at: sourceIndex)
            result.insert(source, at: result.firstIndex(of: target)!)
        }
        assert(result == desired, "\(actual) -> \(result), expected \(desired)")
    }

    private static func checkWithControl(
        visible: [String], hidden: [String], actual: [String], expanded: Bool = true
    ) {
        let positions = Dictionary(uniqueKeysWithValues: actual.enumerated().map {
            ($0.element, CGFloat($0.offset))
        })
        let moves = MenuBarPhysicalOrder.movesToMatch(
            visible: visible, hidden: hidden, expanded: expanded,
            positions: positions, dividerX: positions["<"]!
        )
        var result = actual
        for move in moves {
            let target: String
            switch move.target {
            case .app(let id): target = id
            case .control: target = "<"
            }
            let sourceIndex = result.firstIndex(of: move.sourceID)!
            let targetIndex = result.firstIndex(of: target)!
            if move.placeAfter ? sourceIndex > targetIndex : sourceIndex < targetIndex {
                continue
            }
            result.remove(at: sourceIndex)
            let insertion = result.firstIndex(of: target)! + (move.placeAfter ? 1 : 0)
            result.insert(move.sourceID, at: insertion)
        }
        let desired = (expanded ? hidden : []) + ["<"] + visible
        assert(result == desired, "\(actual) -> \(result), expected \(desired)")
    }

    private static func permutations(_ values: [String]) -> [[String]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index -> [[String]] in
            var rest = values
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }
}
