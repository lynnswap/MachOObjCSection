# 0008 - ObjC 类与实例变量的导出状态查询

- **状态**: Implemented
- **创建日期**: 2026-09-10
- **最后更新**: 2026-09-10
- **所属愿景**: 无
- **配套文档**: [ObjC 导出状态的判定 — 判据、边界与实测](../Internal/ObjCExportStatusResolution.md)（实现说明）
- **对标提案**: MachOSwiftSection 的 0008（导出状态标注）、0016（`--exported-only` 过滤）、0024（导出标志下沉到声明模型）

## 摘要

MachOObjCSection 今天完全没有符号层：整个 `Sources/` 里对 `exportedSymbols` / export trie
的引用是零。于是「这个类是框架真正对外的 API，还是内部实现类」这个事实，调用方拿不到，
只能自己重新解析一遍 Mach-O。

本提案给 `ObjCMetadataSource` 补上这个事实层，回答一个问题：**给定一个 ObjC 类名（或类名 +
实例变量名），它对应的链接器符号在不在这个镜像的 export trie 里**。范围严格限定在库 API：
`objc-section` 的输出一个字节都不变，不加标注、不加过滤开关、不动 snapshot / diff。

对标的是 MachOSwiftSection 那三份提案的**事实层**（`ExportStatus` 四态枚举 + `SymbolIndexStore`
的导出集），不含它们的消费层。语义一并沿用：**这是符号表事实，不是访问级别推断**。ObjC 里
没有 `public` / `private` 之分可供恢复，能说的只有「符号导没导出」。

### 消费场景：全量，不是零星

已知的唯一消费方是 RuntimeViewer（**目前尚未接入，是后续要加的功能**），形态是**在类列表里
对每一个类都标一次**。这不是一个"偶尔查一下"的 API，是一个"一个镜像几百上千个类全过一遍"的
API，本提案的每一处形状选择都由这一条决定 —— 见下面的 API 形状与建表方式。

## 方案

### 判据：实证结论

拿 dyld shared cache 里的 AppKit 与磁盘上的 `DVTKit.framework`（Xcode 的私有框架，非 cache）
实测，四类对象的结论差别很大：

| 对象 | 符号形态 | AppKit（cache） | DVTKit（磁盘） | 判据是否成立 |
|---|---|---|---|---|
| 类 | `_OBJC_CLASS_$_<类名>` | trie 里 667 个 | 定义 167 个类，trie 里 160，其余 7 个是 `non-external` | **成立** |
| 实例变量 | `_OBJC_IVAR_$_<类名>.<ivar 名>` | trie 里 230 个 | 定义 911 个 ivar 符号，trie 里 59，其余 852 个是 `private external` | **成立**，且区分度高 |
| 元类 | `_OBJC_METACLASS_$_<类名>` | 667 个 | 160 个 | 成立但**信息冗余** —— 两处实测都与 `_OBJC_CLASS_$_` 数量完全相等且成对 |
| 协议 | `__OBJC_PROTOCOL_$_<协议名>` | trie 里 **0 个** | 82 个协议符号**全部**是 `non-external (was a private external)` | **不成立** |
| 分类 | 无对应符号 | — | — | **不成立** |

协议那一行是编译器行为而非二进制被 strip：clang 发射 ObjC 协议符号时一律标 `.private_extern`，
链接器合并后 dyld 不导出它们（运行时按名字经 `objc_getProtocol` 查找，不走符号解析）。因此
**ObjC 协议的导出状态在任何二进制上都无法判定**，这是与 Swift 侧最大的差异 —— Swift 的
protocol descriptor（`…Mp`）是正常导出符号。

DVTKit 那 7 个未导出的类是这样的，可以看出这个事实的实际用途：

```
_OBJC_CLASS_$__DVTNSAccessibilityIndexedMockUIElement
_OBJC_CLASS_$__DVTNSPathControlAuxiliary
_OBJC_CLASS_$__TtC6DVTKit35DVTPathControlNavigationPopoverItem
_OBJC_CLASS_$__TtCC6DVTKit25DVTTextCompletionListView13DebugTagLayer
```

前两个是 `_` 前缀的 ObjC 私有类，后两个是 Swift 定义的 `internal` 类。注意 Swift 类的符号名
就是 `_OBJC_CLASS_$_` 直接拼 metadata 里那个已重整的类名（`_TtC6DVTKit35DVT…`），**这条路径
上不需要任何名字重整**。这是 ObjC 侧比 Swift 侧简单的地方：Swift 的 `ExportStatus` 要先从
name node 重整出 `…Mn` / `…Mp`，还得为 constrained extension 留一个「重整不可信」的分支；
ObjC 直接字符串拼接就对得上。

### 判定结果：三态

```swift
// Sources/ObjCMetadataSource/ObjCExportStatus.swift
public enum ObjCExportStatus: Sendable, Hashable {
    /// 符号在镜像的 export trie 里。
    case exported

    /// 镜像有 export trie，且这个符号确定不在里面。
    case notExported

    /// 镜像根本没有 export trie（`.o` 目标文件、静态库产物一类）。
    /// 这是**镜像级**事实：该镜像里任何符号都无从判断，与被查的对象无关。
    case imageHasNoExportInformation
}

extension ObjCExportStatus {
    /// 三态投影：非裁决态是 `nil`。
    public var isExported: Bool? { ... }

    /// 「确定未导出」—— 调用方唯一该据以动手（过滤 / 标灰）的条件。
    public var isDefinitelyNotExported: Bool { self == .notExported }
}
```

**三态而非 Swift 侧的四态**：Swift 的第四态 `descriptorSymbolNameUnresolvable`（这一条声明的
符号名重整不出可信结果）在 ObjC 没有对应物，因为符号名是拼出来的不是重整出来的。

**不设 `notApplicable`**：协议与分类判不了，但它们在这套 API 里**根本没有入口** —— 与其给一个
永远返回「不适用」的函数，不如让调用方在编译期就发现没有这个函数，配文档说明原因。宿主要在
列表里统一处理时，自己用 `Optional<ObjCExportStatus>` 表达「这类对象不判」即可。

### API 形状：一个索引对象，一条路

```swift
// Sources/ObjCMetadataSource/ObjCExportIndex.swift

/// 一个镜像的 ObjC 导出符号索引。建一次，然后对着类列表逐条查。
///
/// 值类型，内部是两个 `Set<String>`，天然 `Sendable` —— 后台线程建好，
/// 主线程渲染时直接查，不需要锁也不需要跨线程调度。
public struct ObjCExportIndex: Sendable {
    /// 遍历一次 export trie 建表。**这是唯一有成本的一步**，之后每次查询是哈希查找。
    public init(machO: some ObjCMetadataSource)

    public func exportStatus(ofClassNamed className: String) -> ObjCExportStatus
    public func exportStatus(ofIvarNamed ivarName: String, inClassNamed className: String) -> ObjCExportStatus
}
```

**只有这一条路，不提供 `machO.objcExportStatus(ofClassNamed:)` 这类直查便利方法。** 初稿里有，
现已删掉：唯一的消费场景是全量遍历，而直查便利方法在全量场景下是个陷阱 —— 每次都要重新拿
`exportTrie`（对 `MachOFile` 要走一遍 `loadCommands`，有文件 I/O）再在 trie 上走一遍，几百个类
就是几百次。给出一条会被误用成 O(n) I/O 的捷径，不如不给。

**不设进程级全局缓存。** MachOSwiftSection 那边的 `SymbolIndexStore` 挂在一个带内存压力监控和
in-flight promise 的 `SharedCache` 基类上，MachOObjCSection 没有这个基座，为一个符号名集合把它
搬过来不值得。生命周期交给调用方：宿主在建自己的索引器时一并建 `ObjCExportIndex` 并持有，
与那个索引器同生共死。

### 建表方式：全表遍历分拣，不用前缀搜索

MachOKit 有 `ExportTrie.search(byKeyPrefix:)`，看起来正好能一次拿到 `_OBJC_CLASS_$_` 打头的
所有项。**不用它**，理由是正确性：它的实现（`TrieTreeProtocol._search(byKeyPrefix:)`）沿 trie
下行时用 `children.first(where:)` —— 前缀走完后若有**多个** child 都以该前缀开头，只会取中一个，
其余分支整个丢掉。它能不能取全，取决于 trie 恰好在 `_OBJC_CLASS_$_` 处有节点边界。标准的
export trie 生成器会把共享前缀压成一层，所以现实中大概率是对的 —— 但「大概率对」不是能拿来
建判据的东西，一旦漏分支就是把一批导出的类静默报成未导出。

改为：**遍历一次 `machO.exportedSymbols`，按前缀分拣**，只留 ObjC 相关的两批，其余丢弃。
AppKit 的量级是 8774 个导出项进、667 个类名 + 230 个 ivar 名出。这也是 MachOSwiftSection 的
`SymbolIndexStore` 建导出集时的做法（无条件遍历 `exportedSymbols`）。

存进 Set 的是**剥掉前缀之后的名字**（`NSAlert` 而不是 `_OBJC_CLASS_$_NSAlert`），查询时直接
拿类名去 `contains`，省掉每次查询的字符串拼接 —— 全量场景下这是几百到几千次拼接。

### 明确不做

- **CLI 一个字节都不动**：不加 `--emit-export-status` 标注，不加 `--exported-only` 过滤，不加
  文件头统计。这些是 MachOSwiftSection 提案 0008 / 0016 的形态，本轮只做它们下面那层事实。
- **不进 `ObjCAPISnapshot` / `ObjCDiffing`**：与 Swift 侧 0024 的判断一致 —— 导出状态是符号化
  状态，不是 API 事实。何况加字段会让所有既有 baseline 的 `formatVersion` 契约失效。
- **不判元类**：与 `_OBJC_CLASS_$_` 成对，两处实测无一例外，多一个入口只是多一份要测的东西。
- **不改 `ObjCInterfaceIndexer`**：RuntimeViewer 用的是它自己那份 `RuntimeObjCInterfaceIndexer`，
  把导出索引塞进库的索引器对它没有帮助。事实层留在 `ObjCMetadataSource`，谁要谁自己建。

### 落地时先验的三件事：结果

三条全部成立，方案未作修改。

1. **MachOKit 的 `ExportedSymbol.name` 带前导下划线** —— 成立。MachOKit 的 trie 代码里
   没有任何剥离逻辑，名字是 trie label 的原始字节。由测试
   `exportTrieSymbolNamesCarryLeadingUnderscore` 钉住：若某个 MachOKit 版本开始剥它，
   所有查询会静默落空、所有类读成 `notExported`，没有崩溃也没有空结果可供察觉。
2. **dyld shared cache 里的 `MachOFile` 能读出 export trie** —— 成立，这是最关键的一条。
   MachOKit 的 `_fileSliceForLinkEditData` 对 cache 镜像有专门分支，会把 linkedit 的读取
   重定向到 cache 自己的段。实测 cache 里的 Foundation 与进程内的 Foundation **逐类判定
   完全一致**（测试 `fileModeAndImageModeAgreeOnEveryClass`）。
3. **`ObjCClassInfo.ivars` 只含本类自己的 ivar** —— 成立。来自 `class_ro_t` 的 `ivars`
   字段。由 ivar 反向验证钉住：trie 里每个 `_OBJC_IVAR_$_<类>.<ivar>` 拆开后，该类必须
   确实声明了这个 ivar。

### 落地时发现的第四条边界：查询是 per-image 的

写测试时撞上的，初稿完全没有预料：**对 Foundation 查 `NSArray`，答案是 `notExported`**。
不是 bug —— `NSArray` 由 CoreFoundation 定义并导出（toll-free bridging 的缘故，`NSDate`、
`NSURL`、`NSDictionary` 同理），Foundation 的 trie 里根本没有它。

答案是对的（问题本就是「这个镜像导出了什么」），但它意味着一条使用契约：**调用方只能拿
本镜像自己定义的类去查**。从某个类的 metadata 里读出的超类名、协议采纳里的类名，经常属于
别的镜像，拿去查会得到一串毫无意义的负面答案，而 API 无法把这种情况与「本镜像定义但未导出」
区分开。

已写进 `exportStatus(ofClassNamed:)` 的文档注释、实现说明与术语表，并由测试
`classDefinedInAnotherImageReadsAsUnexportedHere` 钉住（Foundation 查 `NSArray` 得
`notExported`，CoreFoundation 查得 `exported`）。

### 性能实测：建表是免费的

macOS 26.x / arm64e，dyld shared cache 内的镜像，10 次取中位数：

| 镜像 | 建索引 | 其中 `exportedSymbols` 本身 | 导出符号总数 | 类符号 | ivar 符号 |
|---|---|---|---|---|---|
| Foundation | 40.9 ms | 38.7 ms（94.6%） | 15509 | 397 | 98 |
| AppKit | 23.2 ms | 22.2 ms（95.7%） | 8771 | 667 | 230 |
| SwiftUI | 51.4 ms | 49.2 ms（95.8%） | 19471 | 13 | 0 |

分母：同一台机器上 AppKit 走一遍 `ObjCInterfaceIndexer.prepare()` 是 **27.2 秒**（2573 个
类）。建索引占 **0.085%** —— 无条件建表是免费的，不需要开关也不需要延迟构建，方案里
「若实测意外地贵就回来改」的分支没有触发。

两条附带结论：**瓶颈在 MachOKit 解析 trie**（95%），本模块的分拣循环只占 1 毫秒左右，
所以即便前缀搜索正确也省不下什么；**纯 Swift 框架的索引近乎空表**（SwiftUI 只有 13 个类
符号），这是正常的，与读取失败靠 `exportedSymbols` 总数是否为零区分。

测量代码是一次性的，取到数据后已删除，不留在测试套件里 —— 它没有正确性断言，只会在慢机器
上制造 flaky。

### 测试：`Tests/ObjCMetadataSourceTests/ObjCExportIndexTests.swift`，九条

三条主力：

- **地址交叉验证**（`exportedClassSymbolSitsAtClassRecordAddress`）：断言「符号查得到」是
  同义反复——索引本来就是从这些符号建的。真正有效的是断言导出项的地址**等于该类记录自己的
  地址**，它会在前缀多剥/少剥一个字符、名字拼装错、两种 offset 口径混用时变红。
- **file / image 双模式一致**（`fileModeAndImageModeAgreeOnEveryClass`）：同一个 Foundation，
  一次作为 cache 里的 `MachOFile`、一次作为进程内的 `MachOImage`，逐类比对。这是先验第 2 条
  持续成立的唯一保证，而 cache 镜像正是 RuntimeViewer 的主力场景。
- **ivar 反向验证**（`exportedIvarSymbolsNameDeclaredIvars`）：把 trie 里每个
  `_OBJC_IVAR_$_<类>.<ivar>` 拆开，要求镜像确实在**那个类**上声明了这个 ivar，同时钉住
  先验第 3 条。

其余六条：符号名带前导下划线、区分度不为零（`exported` 与 `notExported` 必须同时出现）、
已知公开类为 `exported`（`NSString` / `NSError` / `NSBundle`）、跨镜像类读作 `notExported`、
ivar 查询按声明类限定、cache 镜像在文件模式下有导出信息。

断言不写死「某某私有类未导出」这类跨 OS 版本不稳的事实，一律用统计性质与交叉验证表达。
cache 相关的三条在没有 dyld shared cache 的机器上自动跳过而非失败。

全套 146 个测试通过（原始退出码，非 xcsift 摘要）。仓库里既有的
`MachOObjCSectionTests` XCTest suite 仍然失败，原因是它的 `setUp` 硬编码了本机路径
`/Users/JH/Downloads/iOS18.5-SwiftUI`；该 suite 未引用本次任何代码，属既有问题，本轮未动。

### 文档

- 本提案原地更新为 `Implemented`。
- 实现说明已写：[ObjC 导出状态的判定 — 判据、边界与实测](../Internal/ObjCExportStatusResolution.md)。
  「协议与分类判不了」「查询是 per-image 的」两条反直觉事实必须留档，否则下一个人会当成漏做。
- 术语表已加 `ObjCExportStatus（导出状态）` 条目。
- `Guides/ObjCSectionCommandLine.md` **未动**——本轮不碰 CLI，使用指南无内容需要同步。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-10 | 建为 Draft | 用户要求「模仿 MachOSwiftSection 增加 Exported 的一些信息」 |
| 2026-09-10 | 范围定为「类 + 实例变量」，不做元类 | 用户选定。元类与类符号两处实测完全成对，是冗余信息 |
| 2026-09-10 | 只做库 API，CLI 完全不动 | 用户选定。标注与过滤（对标 0008 / 0016）留作后续，本轮只铺事实层 |
| 2026-09-10 | 落点选 `ObjCMetadataSource`，不新建 target | 用户选定。它已经是「从 Mach-O 取事实」那一层，且被渲染 / 索引 / 接口 / diff 四个模块全部依赖，加进去所有人立刻能用，不动 `Package.swift` |
| 2026-09-10 | 协议与分类不给查询入口，而非给一个返回「不适用」的入口 | 实证：协议符号一律 `private extern`，AppKit 与 DVTKit 的 trie 里协议数均为 0；分类无符号。编译期发现没这个函数，好过运行期收到一个永远无意义的返回值 |
| 2026-09-10 | 三态枚举，不照抄 Swift 侧的四态 | ObjC 的符号名是拼出来的不是重整出来的，`descriptorSymbolNameUnresolvable` 没有对应物 |
| 2026-09-10 | 不设进程级全局缓存 | 本库没有 `SharedCache` 基座，为一个符号名集合搬一套带内存压力监控的缓存不值得；`ObjCExportIndex` 作为值类型把生命周期交给调用方 |
| 2026-09-10 | 不进 `ObjCAPISnapshot` | 与 MachOSwiftSection 0024 的判断一致：导出状态是符号化状态不是 API 事实；加字段还会破坏既有 baseline 的 `formatVersion` 契约 |
| 2026-09-10 | **删掉初稿里的直查便利方法，只留 `ObjCExportIndex` 一条路** | 用户澄清消费场景是 RuntimeViewer 对**每个类**查一遍。全量场景下直查便利方法是 O(n) 次 trie 遍历加 O(n) 次 `loadCommands` I/O，是个会被误用的陷阱 |
| 2026-09-10 | **建表用全表遍历分拣，不用 `search(byKeyPrefix:)`** | 读了 MachOKit 的 `TrieTreeProtocol._search(byKeyPrefix:)`：前缀走完后用 `children.first(where:)` 取单个分支，多分支时会静默漏项。能不能取全取决于 trie 的压缩形状，不是能拿来建判据的东西 |
| 2026-09-10 | **Set 里存剥掉前缀的名字** | 全量场景下省掉几百到几千次字符串拼接 |
| 2026-09-10 | **把建表耗时列为验收项** | 全量消费意味着这一步直接落在 RuntimeViewer 打开镜像的等待时间里，不能只当实现细节 |
| 2026-09-10 | 用户批准，状态 Draft → Accepted → In Progress | 用户回复「开工」 |
| 2026-09-10 | 落地：三条先验全部成立，方案未改 | 见「落地时先验的三件事：结果」 |
| 2026-09-10 | 新增第四条边界「查询是 per-image 的」，写进 API 文档、实现说明与术语表 | 写测试时撞上：Foundation 查 `NSArray` 返回 `notExported`，因该类归 CoreFoundation。初稿完全没有预料到这个使用陷阱 |
| 2026-09-10 | 性能测量代码用完即删，不留在测试套件里 | 它没有正确性断言，只会在慢机器上制造 flaky；数据落在实现说明里 |
| 2026-09-10 | 状态 → Implemented；配套实现说明已写并登记 | 「协议与分类判不了」「per-image 语义」两条反直觉事实必须留档，否则下一个人会当成漏做 |
