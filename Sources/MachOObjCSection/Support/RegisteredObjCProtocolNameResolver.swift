//
//  RegisteredObjCProtocolNameResolver.swift
//  MachOObjCSection
//

#if canImport(ObjectiveC)
import ObjectiveC
#endif

internal struct RegisteredObjCProtocolNameResolver {
    let protocolAddress: (String) -> UnsafeRawPointer?

    static var runtime: Self? {
#if canImport(ObjectiveC)
        return Self { name in
            guard let objcProtocol = objc_getProtocol(name) else { return nil }
            return UnsafeRawPointer(
                Unmanaged.passUnretained(objcProtocol).toOpaque()
            )
        }
#else
        return nil
#endif
    }
}
