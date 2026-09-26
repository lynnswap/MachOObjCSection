//
//  ObjCDump+ModelDerivations.swift
//  MachOObjCSection
//
//  Pure model-derived accessors over the ObjCDump info types. They live here —
//  not in ObjCDeclarationRendering — because they involve no rendering:
//  diffing (0006) and rendering both key categories by `uniqueName` and read
//  property attributes through these accessors, and sharing one definition
//  keeps the two from drifting.
//

import ObjCDump

extension ObjCCategoryInfo {
    /// The category spelled the way it is indexed and displayed:
    /// `NSString(MyAdditions)`.
    public var uniqueName: String {
        "\(className)(\(name))"
    }
}

extension ObjCPropertyInfo {
    /// The backing ivar named by the property's `V` attribute, if any.
    public var ivar: String? {
        attributes.compactMap(\.ivar).first
    }

    /// The getter named by the property's `G` attribute, if it overrides the
    /// default selector.
    public var customGetter: String? {
        attributes.compactMap(\.getter).first
    }

    /// The setter named by the property's `S` attribute, if it overrides the
    /// default selector.
    public var customSetter: String? {
        attributes.compactMap(\.setter).first
    }
}
