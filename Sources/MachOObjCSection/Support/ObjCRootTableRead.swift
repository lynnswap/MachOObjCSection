//
//  ObjCRootTableRead.swift
//  MachOObjCSection
//

internal struct ObjCRootTableRead<Value> {
    let values: [Value]
    let diagnostics: [ObjCMetadataTableDiagnostic]
}

internal protocol ObjCMetadataPointer: FixedWidthInteger, UnsignedInteger {
    var metadataPointerValue: UInt64 { get }
}

extension UInt32: ObjCMetadataPointer {
    internal var metadataPointerValue: UInt64 { UInt64(self) }
}

extension UInt64: ObjCMetadataPointer {
    internal var metadataPointerValue: UInt64 { self }
}
