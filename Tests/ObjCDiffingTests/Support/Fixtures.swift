import ObjCDump
@testable import ObjCDiffing

/// Hand-built ObjCDump model values — the diff engine is pure value
/// computation, so no Mach-O and no runtime is involved anywhere in this
/// suite.
enum Fixtures {
    static func methodInfo(
        name: String,
        typeEncoding: String = "v16@0:8",
        isClassMethod: Bool = false,
        imp: UInt64 = 0
    ) -> ObjCMethodInfo {
        ObjCMethodInfo(name: name, typeEncoding: typeEncoding, isClassMethod: isClassMethod, imp: imp)
    }

    static func propertyInfo(
        name: String,
        attributesString: String = "T@\"NSString\",C,N,V_backing",
        isClassProperty: Bool = false
    ) -> ObjCPropertyInfo {
        ObjCPropertyInfo(name: name, attributesString: attributesString, isClassProperty: isClassProperty)
    }

    static func ivarInfo(
        name: String,
        typeEncoding: String = "q",
        offset: Int = 8
    ) -> ObjCIvarInfo {
        ObjCIvarInfo(name: name, typeEncoding: typeEncoding, offset: offset)
    }

    static func protocolInfo(
        name: String,
        protocols: [ObjCProtocolInfo] = [],
        classProperties: [ObjCPropertyInfo] = [],
        properties: [ObjCPropertyInfo] = [],
        classMethods: [ObjCMethodInfo] = [],
        methods: [ObjCMethodInfo] = [],
        optionalClassProperties: [ObjCPropertyInfo] = [],
        optionalProperties: [ObjCPropertyInfo] = [],
        optionalClassMethods: [ObjCMethodInfo] = [],
        optionalMethods: [ObjCMethodInfo] = []
    ) -> ObjCProtocolInfo {
        ObjCProtocolInfo(
            name: name,
            protocols: protocols,
            classProperties: classProperties,
            properties: properties,
            classMethods: classMethods,
            methods: methods,
            optionalClassProperties: optionalClassProperties,
            optionalProperties: optionalProperties,
            optionalClassMethods: optionalClassMethods,
            optionalMethods: optionalMethods
        )
    }

    static func classInfo(
        name: String,
        superClassName: String? = "NSObject",
        protocols: [ObjCProtocolInfo] = [],
        ivars: [ObjCIvarInfo] = [],
        classProperties: [ObjCPropertyInfo] = [],
        properties: [ObjCPropertyInfo] = [],
        classMethods: [ObjCMethodInfo] = [],
        methods: [ObjCMethodInfo] = []
    ) -> ObjCClassInfo {
        ObjCClassInfo(
            name: name,
            version: 0,
            imageName: nil,
            instanceSize: 8,
            superClassName: superClassName,
            protocols: protocols,
            ivars: ivars,
            classProperties: classProperties,
            properties: properties,
            classMethods: classMethods,
            methods: methods
        )
    }

    static func categoryInfo(
        name: String,
        className: String,
        protocols: [ObjCProtocolInfo] = [],
        classProperties: [ObjCPropertyInfo] = [],
        properties: [ObjCPropertyInfo] = [],
        classMethods: [ObjCMethodInfo] = [],
        methods: [ObjCMethodInfo] = []
    ) -> ObjCCategoryInfo {
        ObjCCategoryInfo(
            name: name,
            className: className,
            protocols: protocols,
            classProperties: classProperties,
            properties: properties,
            classMethods: classMethods,
            methods: methods
        )
    }

    /// A bare member record for tests that exercise the pure diff/evolution
    /// layers without going through the model projection.
    static func record(
        identity: String,
        payload: String? = nil,
        kind: ObjCMemberKind = .instanceMethod,
        signature: String? = nil,
        isOptionalRequirement: Bool? = nil
    ) -> ObjCMemberRecord {
        ObjCMemberRecord(
            identityKey: ObjCAPIKey(rawValue: identity),
            payloadKey: ObjCAPIKey(rawValue: payload ?? identity),
            kind: kind,
            signature: signature ?? identity,
            isOptionalRequirement: isOptionalRequirement
        )
    }

    static func containerSnapshot(
        key: String,
        name: String? = nil,
        kind: ObjCContainerKind = .class,
        members: [ObjCMemberRecord] = []
    ) -> ObjCContainerSnapshot {
        ObjCContainerSnapshot(
            key: ObjCAPIKey(rawValue: key),
            name: name ?? key,
            kind: kind,
            members: members
        )
    }
}
