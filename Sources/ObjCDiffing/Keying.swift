/// Index a sequence by a derived `ObjCAPIKey`, first element wins. Shared by
/// the two-sided differ and the N-way evolution matrix so both resolve a
/// collision identically.
///
/// On a key collision this keeps the first element and drops the rest — which
/// could hide a removal — so the drop is surfaced, not silent: every keying
/// scope is independently scanned by `ObjCAPISnapshot.keyCollisions()` (same
/// first-wins rule) and the results ride on `ObjCAPIDiff.diagnostics` /
/// `ObjCAPIEvolution.keyCollisionsByVersion` and the reporters' warnings
/// section. The one realistic source is a duplicate class: the runtime allows
/// (and real binaries contain) two same-named ObjC classes in one image.
func keyedFirstWins<Element>(_ elements: [Element], by key: (Element) -> ObjCAPIKey) -> [ObjCAPIKey: Element] {
    var result: [ObjCAPIKey: Element] = [:]
    result.reserveCapacity(elements.count)
    for element in elements {
        let elementKey = key(element)
        if result[elementKey] == nil {
            result[elementKey] = element
        }
    }
    return result
}
