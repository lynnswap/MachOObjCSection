//
//  ObjCRootTableRead.swift
//  MachOObjCSection
//

internal struct ObjCRootTableRead<Value> {
    let values: [Value]
    let diagnostics: [ObjCMetadataTableDiagnostic]
}
