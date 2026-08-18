//
//  ObjCProtocolTraversal.swift
//  MachOObjCSection
//

import Foundation
@_spi(Support) import MachOKit

internal struct ObjCProtocolTraversalContext {
    static let maximumDepth = 64

    enum ReferenceDecision {
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
        tableFailure: ObjCProtocolListTableFailure,
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
}

extension ObjCProtocolProtocol {
    internal func traversalIdentity(in machO: MachOFile) -> ObjCProtocolIdentity {
        .file(
            backing: ObjectIdentifier(machO.fileHandleIdentity),
            offset: offset
        )
    }

    internal func traversalIdentity(in machO: MachOImage) -> ObjCProtocolIdentity? {
        let baseAddress = Int(bitPattern: machO.ptr)
        let (objectAddress, overflow) = baseAddress.addingReportingOverflow(offset)
        guard !overflow else { return nil }
        return .image(address: UInt(bitPattern: objectAddress))
    }
}
