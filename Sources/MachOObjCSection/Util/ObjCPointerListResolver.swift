//
//  ObjCPointerListResolver.swift
//
//
//  Created by OpenAI Codex on 2026/03/22.
//
//

import Foundation
@_spi(Support) import MachOKit

struct ObjCPointerListBindTarget {
    let libraryOrdinalType: BindSpecial?
    let symbolName: String?
    let addend: UInt64
}

enum ObjCPointerListResolveResult {
    case resolved(ResolvedValue)
    case skippedExternalBind(symbolName: String?)
    case unresolvedBind(symbolName: String?)
    case unresolved
}

enum ObjCPointerListResolver {
    static func resolve(
        unresolved: UnresolvedValue,
        resolveRebase: (UnresolvedValue) -> ResolvedValue?,
        resolveBind: (Int) -> ObjCPointerListBindTarget?,
        resolveSelfBind: (String, UInt64) -> ResolvedValue?,
        resolveRaw: (UnresolvedValue) -> ResolvedValue?
    ) -> ObjCPointerListResolveResult {
        if let resolved = resolveRebase(unresolved) {
            return .resolved(resolved)
        }

        guard let bind = resolveBind(unresolved.fieldOffset) else {
            if let resolved = resolveRaw(unresolved) {
                return .resolved(resolved)
            }
            return .unresolved
        }

        guard bind.libraryOrdinalType == .dylib_self else {
            return .skippedExternalBind(symbolName: bind.symbolName)
        }

        guard let symbolName = bind.symbolName,
              let resolved = resolveSelfBind(symbolName, bind.addend) else {
            return .unresolvedBind(symbolName: bind.symbolName)
        }

        return .resolved(resolved)
    }
}

extension MachOFile {
    func resolveRebaseIfPresent(
        _ unresolvedValue: UnresolvedValue
    ) -> ResolvedValue? {
        let offset: UInt64 = numericCast(unresolvedValue.fieldOffset)

        if let (cache, cacheOffset) = cacheAndFileOffset(fromStart: offset) {
            guard let address = cache.resolveOptionalRebase(at: cacheOffset) else {
                return nil
            }
            return .init(
                address: address,
                offset: address - cache.mainCacheHeader.sharedRegionStart
            )
        }

        guard let resolved = resolveOptionalRebase(at: offset) else {
            return nil
        }

        let resolvedOffset = fileOffset(of: resolved)
            ?? numericCast(unresolvedValue.fieldOffset)
        return .init(
            address: resolved,
            offset: resolvedOffset
        )
    }

    func resolveObjCPointerListTarget(
        _ unresolved: UnresolvedValue
    ) -> ObjCPointerListResolveResult {
        ObjCPointerListResolver.resolve(
            unresolved: unresolved,
            resolveRebase: { self.resolveRebaseIfPresent($0) },
            resolveBind: { fileOffset in
                guard let (importInfo, addend) = self.resolveBind(
                    at: numericCast(fileOffset)
                ) else {
                    return nil
                }

                let symbolName = self.dyldChainedFixups?.symbolName(
                    for: importInfo.info.nameOffset
                )
                return .init(
                    libraryOrdinalType: importInfo.info.libraryOrdinalType,
                    symbolName: symbolName,
                    addend: addend
                )
            },
            resolveSelfBind: { symbolName, addend in
                self.resolveObjCSelfBindTarget(
                    symbolName: symbolName,
                    addend: addend
                )
            },
            resolveRaw: { unresolved in
                self.resolveObjCRawPointerTarget(unresolved.value)
            }
        )
    }

    func resolveObjCSelfBindTarget(
        symbolName: String,
        addend: UInt64
    ) -> ResolvedValue? {
        let baseOffset: UInt64?
        if let export = exportTrie?.search(by: symbolName),
           let offset = export.offset {
            baseOffset = numericCast(offset)
        } else if let symbol = symbol(
            named: symbolName,
            mangled: true,
            isGlobalOnly: true
        ) {
            baseOffset = numericCast(symbol.offset)
        } else {
            baseOffset = nil
        }

        guard let baseOffset else { return nil }

        let targetOffset = baseOffset + addend
        if let cache {
            let address = cache.mainCacheHeader.sharedRegionStart + targetOffset
            return .init(address: address, offset: targetOffset)
        }

        let fileOffset = fileOffset(of: targetOffset) ?? targetOffset
        return .init(address: targetOffset, offset: fileOffset)
    }

    func resolveObjCRawPointerTarget(
        _ rawValue: UInt64
    ) -> ResolvedValue? {
        if let (resolvedCache, _) = cacheAndFileOffset(for: rawValue) {
            return .init(
                address: rawValue,
                offset: rawValue - resolvedCache.mainCacheHeader.sharedRegionStart
            )
        }

        guard let offset = fileOffset(of: rawValue) else {
            return nil
        }
        return .init(address: rawValue, offset: offset)
    }

    func readObjCLayout<Layout>(
        at resolved: ResolvedValue,
        as _: Layout.Type
    ) -> (MachOFile, Layout)? {
        guard let (fileHandle, fileOffset) = fileHandleAndOffset(
            forAddress: resolved.address
        ) else {
            return nil
        }

        var targetMachO = self
        if !targetMachO.contains(unslidAddress: resolved.address),
           let cache = self.cache(for: resolved.address),
           let machO = cache.machO(containing: resolved.address) {
            targetMachO = machO
        }

        let layout: Layout = fileHandle.read(offset: fileOffset)
        return (targetMachO, layout)
    }
}
