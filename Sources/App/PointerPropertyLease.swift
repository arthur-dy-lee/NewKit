/// A device property can be restored only while its current value is still
/// the value NK last wrote. A later write by Smooze or System Settings wins.
struct PointerPropertyLease {
    let originalValue: Int32
    private(set) var lastAppliedValue: Int32?

    mutating func didApply(_ value: Int32) {
        lastAppliedValue = value
    }

    func valueToRestore(currentValue: Int32?) -> Int32? {
        guard let applied = lastAppliedValue, currentValue == applied else { return nil }
        return originalValue
    }
}
