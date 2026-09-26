import Foundation

extension RangeReplaceableCollection {
    /// The collection with every element matching `predicate` removed.
    ///
    /// The non-mutating counterpart of `removeAll(where:)`, used to build the
    /// stripped copies of an `ObjCClassInfo` / `ObjCProtocolInfo`.
    func removingAll(where predicate: (Element) throws -> Bool) rethrows -> Self {
        var copy = self
        try copy.removeAll(where: predicate)
        return copy
    }
}

extension Set {
    /// Inserts every element of `elements`.
    mutating func insert(contentsOf elements: some Sequence<Element>) {
        for element in elements {
            insert(element)
        }
    }
}
