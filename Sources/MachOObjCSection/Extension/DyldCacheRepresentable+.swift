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
            return numericCast(objcOpt.layout.relativeMethodSelectorBaseAddressOffset)
        }
        if let oldOpt = oldObjcOptimization {
            switch oldOpt {
            case .v16(let optimization):
                return numericCast(optimization.layout.relativeMethodSelectorBaseAddressOffset) + numericCast(optimization.offset)
            default:
                return nil
            }
        }
        return nil
    }
}
