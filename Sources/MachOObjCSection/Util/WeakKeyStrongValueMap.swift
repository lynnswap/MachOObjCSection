//
//  WeakKeyStrongValueMap.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2026/02/08
//  
//

import Foundation

#if !canImport(ObjectiveC)
final class WeakBox<Value: AnyObject> {
    weak var value: Value?
    let id: ObjectIdentifier

    init(_ value: Value) {
        self.value = value
        self.id = ObjectIdentifier(value)
    }
}

struct WeakKeyStrongValueMap<Key: AnyObject, Value> {
    private var storage: [ObjectIdentifier: (key: WeakBox<Key>, value: Value)] = [:]

    mutating func object(forKey key: Key) -> Value? {
        cleanupIfNeeded()
        return storage[ObjectIdentifier(key)]?.value
    }

    mutating func setObject(_ value: Value, forKey key: Key) {
        cleanupIfNeeded()
        let box = WeakBox(key)
        storage[box.id] = (box, value)
    }

    private mutating func cleanupIfNeeded() {
        storage = storage.filter { $0.value.key.value != nil }
    }
}
#endif
