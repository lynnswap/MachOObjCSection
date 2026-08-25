//
//  ObjCProtocolTraversal.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

internal struct ObjCProtocolTraversalContext {
    static let maximumDepth = 64

    enum ReferenceDecision: Equatable {
        case descend
        case shallowCycle
        case shallowLimit
    }

    private struct PathElement {
        let identity: ObjCProtocolIdentity
        let name: String
    }

    let subject: ObjCProtocolDiagnostic.Subject
    private var path: [PathElement]
    private var activeIdentities: Set<ObjCProtocolIdentity>
    private(set) var edgeDepth: Int
    private(set) var diagnostics: [ObjCProtocolDiagnostic] = []
    private(set) var memberListDiagnostics: [ObjCMemberListDiagnostic] = []

    init(
        subject: ObjCProtocolDiagnostic.Subject,
        rootProtocol: (identity: ObjCProtocolIdentity, name: String)? = nil
    ) {
        self.subject = subject
        if let rootProtocol {
            self.path = [
                .init(identity: rootProtocol.identity, name: rootProtocol.name)
            ]
            self.activeIdentities = [rootProtocol.identity]
        } else {
            self.path = []
            self.activeIdentities = []
        }
        self.edgeDepth = 0
    }

    var protocolPath: [String] {
        path.map(\.name)
    }

    mutating func decision(
        for identity: ObjCProtocolIdentity,
        name: String
    ) -> ReferenceDecision {
        let diagnosticPath = protocolPath + [name]
        if activeIdentities.contains(identity) {
            diagnostics.append(
                .cycle(.init(subject: subject, protocolPath: diagnosticPath))
            )
            return .shallowCycle
        }
        if edgeDepth >= Self.maximumDepth {
            diagnostics.append(
                .recursionLimit(
                    .init(
                        subject: subject,
                        protocolPath: diagnosticPath,
                        maximumDepth: Self.maximumDepth
                    )
                )
            )
            return .shallowLimit
        }
        return .descend
    }

    mutating func enter(
        identity: ObjCProtocolIdentity,
        name: String
    ) {
        let inserted = activeIdentities.insert(identity).inserted
        precondition(inserted, "cycle must be checked before entering a protocol")
        path.append(.init(identity: identity, name: name))
        edgeDepth += 1
    }

    mutating func leave(identity: ObjCProtocolIdentity) {
        let removed = path.removeLast()
        precondition(removed.identity == identity, "protocol traversal must unwind in path order")
        precondition(activeIdentities.remove(identity) != nil, "active protocol identity must exist")
        edgeDepth -= 1
    }

    mutating func record(
        tableFailure: ObjCMetadataTableFailure,
        listOffset: Int
    ) {
        diagnostics.append(
            .unreadableList(
                .init(
                    subject: subject,
                    protocolPath: protocolPath,
                    listOffset: listOffset,
                    failure: tableFailure.diagnosticFailure
                )
            )
        )
    }

    mutating func record(resolutionFailure: ObjCProtocolListResolutionFailure) {
        diagnostics.append(
            .unreadableList(
                .init(
                    subject: subject,
                    protocolPath: protocolPath,
                    listOffset: resolutionFailure.listOffset,
                    failure: resolutionFailure.failure
                )
            )
        )
    }

    mutating func record(
        memberListFailure: ObjCRelativeListFailure,
        className: String,
        kind: ObjCMemberListDiagnostic.Kind
    ) {
        memberListDiagnostics.append(
            .init(
                className: className,
                kind: kind,
                outerListOffset: memberListFailure.outerListOffset,
                location: memberListFailure.location.memberDiagnosticLocation,
                failure: memberListFailure.reason.memberDiagnosticFailure
            )
        )
    }

    mutating func record(
        entryFailure: ObjCProtocolListEntryFailure,
        listOffset: Int
    ) {
        diagnostics.append(
            .unreadableList(
                .init(
                    subject: subject,
                    protocolPath: protocolPath,
                    listOffset: listOffset,
                    failure: entryFailure.diagnosticFailure
                )
            )
        )
    }

    mutating func recordInvalidRootIdentity(protocolOffset: Int) {
        diagnostics.append(
            .invalidIdentity(
                .init(subject: subject, protocolOffset: protocolOffset)
            )
        )
    }
}

extension ObjCProtocolProtocol {
    internal func traversalIdentity(in machO: MachOFile) -> ObjCProtocolIdentity? {
        machO.traversalIdentity(protocolOffset: offset)
    }

    internal func traversalIdentity(in machO: MachOImage) -> ObjCProtocolIdentity? {
        guard let objectAddress = addingSignedDisplacement(
            offset,
            to: UInt(bitPattern: machO.ptr)
        ) else { return nil }
        return .image(address: objectAddress)
    }
}

extension MachOFile {
    internal func traversalIdentity(
        protocolOffset: Int,
        unslidAddress: UInt64? = nil
    ) -> ObjCProtocolIdentity? {
        if let cache {
            let address: UInt64
            if let unslidAddress {
                address = unslidAddress
            } else {
                guard let offset = UInt64(exactly: protocolOffset),
                      let canonicalAddress = checkedCacheAddress(
                        sharedRegionStart: cache.mainCacheHeader.sharedRegionStart,
                        offset: offset
                      ) else { return nil }
                address = canonicalAddress
            }
            return .cache(
                uuid: cache.mainCacheHeader.uuid,
                unslidAddress: address
            )
        }

        guard protocolOffset >= 0, headerStartOffset >= 0 else { return nil }
        return .file(
            path: url.standardizedFileURL.path,
            headerOffset: headerStartOffset,
            protocolOffset: protocolOffset
        )
    }
}
