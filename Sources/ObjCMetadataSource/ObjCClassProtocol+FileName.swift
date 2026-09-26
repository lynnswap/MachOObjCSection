import Foundation
import MachOKit
import MachOObjCSection

extension ObjCClassProtocol {
    /// The class name as recorded in this file's read-only class data.
    ///
    /// `MachOObjCSection` ships `name(in: MachOImage)` but no file-mode
    /// counterpart, which was the one genuine gap standing between the indexing
    /// layer and `MachOFile`. It is filled here rather than upstream because
    /// the pieces already exist: `ObjCClassRODataProtocol.name(in: MachOFile)`
    /// does the actual reading, so this is a one-line composition and no
    /// upstream file has to be touched.
    ///
    /// The image-mode version additionally consults RW data, which the runtime
    /// writes when it realizes a class. A file on disk has none, so RO data is
    /// the whole story here.
    public func name(in machO: MachOFile) -> String? {
        classROData(in: machO)?.name(in: machO)
    }
}
