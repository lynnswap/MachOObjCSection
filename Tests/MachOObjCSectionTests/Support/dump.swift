//
//  dump.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2024/11/02
//  
//

import MachOObjCSection
import ObjCDump
import XCTest

func dump(
    imageInfo: ObjCImageInfo
) {
    print("Flags:", imageInfo.flags.bits)
    print("Version:", imageInfo.version)
    print("SwiftUnstableVersion:", imageInfo.flags.swiftUnstableVersion?.description ?? "")
    print("SwiftStableVersion:", imageInfo.flags.swiftStableVersion)
}

func dump(
    list: ObjCMethodList,
    in machO: MachOFile,
    isClass: Bool = false
) {
    guard let methods = list.methods(in: machO) else {
        return
    }
    for m in methods {
        let info = ObjCMethodInfo(
            name: m.name,
            typeEncoding: m.types,
            isClassMethod: isClass
        )
        if info.headerString.contains("unknown") {
            print(" M", info.headerString, info.typeEncoding, info.name)
        } else {
            print(" M", info.headerString)
        }
    }
}

func dump(
    list: ObjCMethodList,
    in machO: MachOImage,
    isClass: Bool = false
) {
    let methods = list.methods(in: machO)
    for m in methods {
        let info = ObjCMethodInfo(
            name: m.name,
            typeEncoding: m.types,
            isClassMethod: isClass
        )
        if info.headerString.contains("unknown") {
            print(" M", info.headerString, info.typeEncoding, info.name)
        } else {
            print(" M", info.headerString)
        }
    }
}
