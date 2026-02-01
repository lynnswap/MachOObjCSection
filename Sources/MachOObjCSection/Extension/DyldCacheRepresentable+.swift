//
//  DyldCacheRepresentable+.swift
//  MachOObjCSection
//
//  Created by p-x9 on 2025/10/12
//  
//

import Foundation
import MachOKit

extension DyldCacheRepresentable {
    var relativeMethodSelectorBaseAddressOffset: UInt64? {
        if let objcOpt = objcOptimization {
            return objcOpt.relativeMethodSelectorBaseAddressOffset
        }
        if let oldOpt = oldObjcOptimization {
            return numericCast(oldOpt.relativeMethodSelectorBaseAddressOffset) + numericCast(oldOpt.offset)
        }
        return nil
    }
}
