//
//  ObjCRootTableRead.swift
//  MachOObjCSection
//

internal struct ObjCRootTableRead<Value> {
    let values: [Value]
    let diagnostics: [ObjCMetadataTableDiagnostic]
}

internal protocol ObjCRootPointer: FixedWidthInteger, UnsignedInteger {
    var rootPointerValue: UInt64 { get }
}

extension UInt32: ObjCRootPointer {
    internal var rootPointerValue: UInt64 { UInt64(self) }
}

extension UInt64: ObjCRootPointer {
    internal var rootPointerValue: UInt64 { self }
}
