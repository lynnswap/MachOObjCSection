import ObjCDump
import Testing
@testable import ObjCDiffing

@Suite("ObjCMemberRecord projection")
struct ObjCMemberRecordTests {
    @Test func instanceMethodKeysOnSelectorWithEncodingPayload() {
        let record = ObjCMemberRecord.make(Fixtures.methodInfo(name: "doSomething:", typeEncoding: "v24@0:8@16"))
        #expect(record.identityKey.rawValue == "method:-doSomething:")
        #expect(record.payloadKey.rawValue == "enc:v24@0:8@16")
        #expect(record.kind == .instanceMethod)
        #expect(record.isOptionalRequirement == nil)
    }

    @Test func classMethodIdentityIsDistinctFromInstanceMethod() {
        let instanceRecord = ObjCMemberRecord.make(Fixtures.methodInfo(name: "shared"))
        let classRecord = ObjCMemberRecord.make(Fixtures.methodInfo(name: "shared", isClassMethod: true))
        #expect(classRecord.identityKey.rawValue == "method:+shared")
        #expect(classRecord.kind == .classMethod)
        #expect(instanceRecord.identityKey != classRecord.identityKey)
    }

    @Test func differentIMPAddressesProduceEqualRecords() {
        let firstBuild = ObjCMemberRecord.make(Fixtures.methodInfo(name: "run", imp: 0x1000))
        let secondBuild = ObjCMemberRecord.make(Fixtures.methodInfo(name: "run", imp: 0x2000))
        #expect(firstBuild == secondBuild)
    }

    @Test func propertyPayloadStripsBackingIvarAttribute() {
        let firstIvarName = ObjCMemberRecord.make(Fixtures.propertyInfo(name: "title", attributesString: "T@\"NSString\",C,N,V_title"))
        let secondIvarName = ObjCMemberRecord.make(Fixtures.propertyInfo(name: "title", attributesString: "T@\"NSString\",C,N,V_renamedTitle"))
        #expect(firstIvarName.payloadKey == secondIvarName.payloadKey)

        let readonlyVariant = ObjCMemberRecord.make(Fixtures.propertyInfo(name: "title", attributesString: "T@\"NSString\",R,C,N,V_title"))
        #expect(firstIvarName.payloadKey != readonlyVariant.payloadKey)
        #expect(firstIvarName.identityKey == readonlyVariant.identityKey)
    }

    @Test func classPropertyIdentityIsDistinctFromInstanceProperty() {
        let instanceRecord = ObjCMemberRecord.make(Fixtures.propertyInfo(name: "shared"))
        let classRecord = ObjCMemberRecord.make(Fixtures.propertyInfo(name: "shared", isClassProperty: true))
        #expect(instanceRecord.identityKey.rawValue == "property:-shared")
        #expect(classRecord.identityKey.rawValue == "property:+shared")
        #expect(classRecord.kind == .classProperty)
    }

    @Test func ivarPayloadExcludesOffset() {
        let smallOffset = ObjCMemberRecord.make(Fixtures.ivarInfo(name: "_count", offset: 8))
        let largeOffset = ObjCMemberRecord.make(Fixtures.ivarInfo(name: "_count", offset: 24))
        #expect(smallOffset.payloadKey == largeOffset.payloadKey)
        #expect(smallOffset.identityKey.rawValue == "ivar:_count")
        #expect(smallOffset.kind == .ivar)

        let retyped = ObjCMemberRecord.make(Fixtures.ivarInfo(name: "_count", typeEncoding: "d"))
        #expect(smallOffset.payloadKey != retyped.payloadKey)
    }

    @Test func optionalityTravelsInPayloadNotIdentity() {
        let requiredRecord = ObjCMemberRecord.make(Fixtures.methodInfo(name: "render"), isOptionalRequirement: false)
        let optionalRecord = ObjCMemberRecord.make(Fixtures.methodInfo(name: "render"), isOptionalRequirement: true)
        #expect(requiredRecord.identityKey == optionalRecord.identityKey)
        #expect(requiredRecord.payloadKey != optionalRecord.payloadKey)
        #expect(requiredRecord.isOptionalRequirement == false)
        #expect(optionalRecord.isOptionalRequirement == true)
    }

    @Test func protocolAdoptionIsIdentityOnly() {
        let record = ObjCMemberRecord.makeProtocolAdoption(protocolName: "NSCopying")
        #expect(record.identityKey.rawValue == "adopts:NSCopying")
        #expect(record.identityKey == record.payloadKey)
        #expect(record.kind == .protocolAdoption)
    }

    @Test func superclassPseudoMemberFoldsNameIntoPayload() {
        let onNSObject = ObjCMemberRecord.makeSuperclass(superclassName: "NSObject")
        let onNSView = ObjCMemberRecord.makeSuperclass(superclassName: "NSView")
        let onRoot = ObjCMemberRecord.makeSuperclass(superclassName: nil)
        #expect(onNSObject.identityKey == onNSView.identityKey)
        #expect(onNSObject.payloadKey != onNSView.payloadKey)
        #expect(onRoot.payloadKey.rawValue == "super:")
        #expect(onNSObject.kind == .superclass)
    }

    @Test func requiredAdditionOverridesToBreaking() {
        let requiredRecord = Fixtures.record(identity: "method:-render", isOptionalRequirement: false)
        let optionalRecord = Fixtures.record(identity: "method:-render", isOptionalRequirement: true)
        let plainRecord = Fixtures.record(identity: "method:-render")
        #expect(ObjCMemberRecord.compatibilityOverride(old: nil, new: requiredRecord) == .breaking)
        #expect(ObjCMemberRecord.compatibilityOverride(old: nil, new: optionalRecord) == nil)
        #expect(ObjCMemberRecord.compatibilityOverride(old: nil, new: plainRecord) == nil)
        #expect(ObjCMemberRecord.compatibilityOverride(old: plainRecord, new: nil) == nil)
    }
}
