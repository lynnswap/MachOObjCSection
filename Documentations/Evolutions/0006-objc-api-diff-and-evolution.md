# 0006 - ObjC API Diff 与多版本 Evolution 追踪

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-20
- **最后更新**: 2026-08-20
- **所属愿景**: 无
- **关联提案**: [0001](0001-objc-rendering-and-indexing-downstreaming.md) / [0002](0002-objc-machofile-genericization-and-cli.md)（「与 MachOSwiftSection 能力对齐」路线的延续）
- **实现分支 / PR**: main
- **配套文档**: [实现说明《ObjC API Diff — 设计与已知局限》](../Internal/ObjCAPIDiffDesignAndLimitations.md)；[CLI 使用指南](../Guides/ObjCSectionCommandLine.md)（新增 snapshot / diff / evolution 章节与 formatVersion 契约）；术语登记于[项目术语表](../Glossary.md)与全局术语表

## 摘要

为 MachOObjCSection 增加与 MachOSwiftSection 的 `SwiftDiffing` 对等的比对能力：比对两个二进制的
ObjC metadata（class / protocol / category 及其 method / property / ivar / protocol 采纳），产出结构化的
API diff；把一个二进制的 ObjC API 冻结为可持久化的 JSON 快照（baseline），无需原二进制即可比对；
以及跨 N ≥ 2 个有序版本追踪每个声明的生命线（lineage）。落点为一个新的 `ObjCDiffing` library target，
外加 `objc-section` CLI 的三个新子命令 `snapshot` / `diff` / `evolution`（选项拼写与 `swift-section`
完全对齐）。

## 动机

MachOSwiftSection 已具备完整的 Swift ABI diff / snapshot / evolution 能力
（`Sources/SwiftDiffing/`，2300 行；CLI 的 `snapshot` / `diff` / `evolution` 三个子命令），可以回答
「SwiftUICore 从 iOS 17 到 26 每个声明何时出现、何时被改、何时消失」这类问题。ObjC 侧完全没有
对应能力：`objc-section` 只有 `dump` 和 `interface` 两个子命令，只能整体输出单个二进制的接口文本；
想比较两个 OS 版本里同一框架的 ObjC 接口变化，目前只能各 dump 一份再用文本 `diff`，而文本 diff：

- 分不清「method 换 typeEncoding」（modified）与「method 消失 + 新 method 出现」（removed + added）；
- 受渲染选项（`ObjCGenerationOptions` 十个开关、C 类型替换、ivar offset 注释）干扰，两次 dump
  参数稍有不同就满屏假差异；
- 无法持久化为与渲染无关的 baseline，更无法做 N 版本的时间线。

系统框架的主体（AppKit / UIKit / Foundation 的类簇、delegate 协议）仍是 ObjC metadata，逆向工程
场景（RuntimeViewer、跨 OS 版本追私有类演化）对 ObjC 侧的需求与 Swift 侧完全同构。0001 / 0002
已把渲染、索引、CLI 三层对齐到 MachOSwiftSection 的水平，diff / evolution 是这条路线上缺的最后
一块。

## 前期调研

以下事实均已查证（本节路径省略仓库根 `/Volumes/Code/Personal/`）：

- **参考实现的完整结构** —— `MachOSwiftSection/Sources/SwiftDiffing/` 共 15 个文件：
  `ABIKey`（remangle 身份）、`MemberRecord`（`identityKey` 匹配 + `payloadKey` 变更检测的双键设计）、
  `ABIDiffer`（freeze + 三路集合差分，live 与 baseline 共用一套算法）、`ABISnapshot` /
  `ABISnapshotDocument`（formatVersion 版本头 + provenance）、`ABIEvolutionBuilder`（key → 逐版本
  presence/payload 矩阵，N == 2 时与双侧 diff 严格一致）、`Compatibility`（additive / breaking 判定与
  记录级 refinement）、`ABIDiagnostics`（键碰撞与 remangle 回退的诊断通道）、两个纯文本 reporter。
  CLI 侧 `swift-section` 的 `SnapshotCommand` / `DiffCommand` / `EvolutionCommand` 共享
  `ABISnapshotInputLoader`（按首个非空白字节是否为 `{` 嗅探输入是快照 JSON 还是 Mach-O）。
  设计文档 `MachOSwiftSection/Documentations/Internal/ABIDiffDesignAndLimitations.md` 与
  `ABIEvolutionDesign.md` 记录了全部取舍。
- **ObjC 语义模型在外部包，非 `Codable`** —— class / protocol / category / method / property / ivar 的
  语义模型是 swift-objc-dump 包的 `ObjCClassInfo` / `ObjCProtocolInfo` / `ObjCCategoryInfo` /
  `ObjCMethodInfo` / `ObjCPropertyInfo` / `ObjCIvarInfo`（`swift-objc-dump/Sources/ObjCDump/Model/`，
  全部 `public struct … : Sendable, Equatable`，**没有 `Codable`，也没有 `Hashable`**）。本仓库没有
  MachOSwiftSection 那种本地 `*Definition` 层——`*Info` 就是模型层。因此持久化快照必须在本仓库
  定义自己的投影记录（与参考实现的 `MemberRecord` 思路一致），而不是给外部类型加 retroactive
  `Codable`。
- **稳定身份天然齐备，无需 remangle** —— class 身份是 `name`；protocol 身份是 `name`；category
  身份是 `uniqueName`（`ClassName(CategoryName)`，定义在
  `MachOObjCSection/Sources/ObjCDeclarationRendering/ObjCDump+SemanticString.swift:770`，实现为
  `"\(className)(\(name))"`）；method 身份是 `isClassMethod` + selector（`ObjCMethodInfo.name`）；
  property 身份是 `isClassProperty` + `name`；ivar 身份是 `name`。参考实现里 `ABIKey` 的
  `.mangled` / `.printed` 双 case 与 remangle 回退诊断是 Swift mangling 特有的问题，ObjC 侧不存在。
- **变更载荷字段** —— method 的 `typeEncoding: String`、ivar 的 `typeEncoding: String`、property 的
  `attributes: [ObjCPropertyAttribute]`（解析自 `attributesString`）、class 的 `superClassName: String?`。
  其中三个字段**不稳定或非接口事实，必须排除出比较**：`ObjCMethodInfo.imp`（地址，每次构建都变）、
  `ObjCIvarInfo.offset`（non-fragile ABI 下由运行时滑动，且一处插入会级联移动其后所有 ivar）、
  `ObjCClassInfo.imageName` / `instanceSize`（派生值）。property 的 `V` 属性（backing ivar 名，如
  `V_foo`）是合成实现细节，ivar 名变化会由 ivar 轴自己报告，折入 property payload 只会重复报噪声。
- **协议列表递归展开问题** —— indexer 生成 info 时用默认 options（`.recursive`，
  `MachOObjCSection/Sources/ObjCIndexing/ObjCInterfaceIndexer.swift:352` 调 `objcProtocolInfo(of:)`
  便捷版），`protocols: [ObjCProtocolInfo]` 是递归物化的完整树，直接序列化会指数膨胀。但树的
  **第一层就是直接采纳的协议**，快照投影只取 `protocols.map(\.name)` 即可，无需以
  `ObjCInfoOptions.headerDump`（`MachOObjCSection/Sources/MachOObjCSection/Support/ObjCDump.swift:33`）
  重新生成 info。
- **索引器已提供全量访问** —— `ObjCInterfaceIndexer` 有 `classNames` / `protocolNames` /
  `categoryNames` 与 `classGroup(forName:)` / `protocolGroup(forName:)` / `categoryGroup(forName:)`
  （`ObjCInterfaceIndexer.swift:501-534`）。`ObjCClassGroup.info` 是 `[ObjCClassInfo]`，`info.first`
  是类自身、其余是超类链——快照只投影 `info.first`（本类自己声明的成员），超类的变化由超类自己的
  容器报告，不重复。
- **模型派生扩展的位置问题** —— `ObjCCategoryInfo.uniqueName`、`ObjCPropertyInfo.ivar` /
  `.customGetter` / `.customSetter` 这四个纯模型派生的 extension 目前定义在渲染层
  `ObjCDeclarationRendering`（`ObjCDump+SemanticString.swift:768-795`）。`ObjCDiffing` 需要
  `uniqueName` 做 category 身份，但不应为此拖上渲染依赖。
- **CLI 现状** —— `objc-section` 有 `DumpCommand` / `InterfaceCommand`，共享
  `MachOOptionGroup`（拼写刻意与 `swift-section` 一致，见
  `Sources/objc-section/Models/MachOOptionGroup.swift` 的注释）与
  `MachOFile.load(options:)`（`Sources/objc-section/Utilities/MachOFile+Load.swift`）。
- **重复类名真实存在** —— 同一 image 中出现同名 ObjC 类是运行时允许且实际发生的（duplicate
  class warning），参考实现的键碰撞诊断通道（first-wins + 上浮告警）在 ObjC 侧同样必要。
- **测试现状** —— 测试用 swift-testing；fixture 走「当前进程已加载的 image」
  （`MachOImage(name: "Foundation")` 或测试目标内自声明 `@objc` 类），没有 baseline/golden 机制。
  参考实现的 diff 单元测试全部手工构造纯值记录，不需要二进制，本仓库可照搬该风格。

## 提议方案

新增 library target **`ObjCDiffing`**（对应新 product），完整移植 SwiftDiffing 的四层能力，按 ObjC
语义简化与调整：

1. **双键记录**：每个成员投影为 `ObjCMemberRecord`，`identityKey` 负责两侧匹配（added / removed），
   `payloadKey` 负责已匹配成员的变更检测（modified）。身份用带命名空间前缀的稳定字符串
   （`method:-foo:`、`property:+bar`、`ivar:_baz`、`adopts:NSCopying`、`superclass`），无 remangle、
   无回退路径。
2. **快照与持久化**：`ObjCAPISnapshot`（classes / protocols / categories 三个容器 bucket）→
   `ObjCAPISnapshotDocument`（formatVersion 版本头 + `ObjCAPIProvenance`）。JSON 编码统一走
   sortedKeys + prettyPrinted + ISO-8601，同一快照编码两次字节一致，baseline 可进 git。
3. **双侧 diff**：`ObjCAPIDiffer` 提供 `snapshot(of:)`（唯一接触模型的冻结点）与三个 `diff` 入口
   （live module / document / snapshot），live diff = 冻结后 diff，两条路径共用一套算法。输出
   `ObjCAPIDiff`，确定性排序，`Codable + Equatable`。
4. **兼容性判定**：`ObjCCompatibility`（additive / breaking）+ 一条记录级 refinement：protocol 新增
   **required** 成员判 breaking（现有 conformer 缺实现），新增 **optional** 成员判 additive——与参考
   实现的 `hasDefaultImplementation` refinement 结构同构。
5. **Evolution**：`ObjCAPIEvolutionBuilder` 按 key → 逐版本 presence/payload 矩阵直接构建
   `ObjCAPIEvolution`（不做 N−1 次 pairwise join），N == 2 时事件集与双侧 diff 严格一致。
6. **诊断通道**：键碰撞（duplicate class / duplicate selector）first-wins 保留、诊断上浮、reporter
   渲染 Warnings 段。ObjC 侧没有 remangle 回退，该维度整体不存在。
7. **CLI**：`objc-section` 新增 `snapshot` / `diff` / `evolution` 三个子命令，选项拼写与
   `swift-section` 对应命令逐一对齐；共享的输入嗅探与加载逻辑放进
   `ObjCSnapshotInputLoader`。
8. **前置小重构**：把 `uniqueName` / `ivar` / `customGetter` / `customSetter` 四个模型派生 extension
   从 `ObjCDeclarationRendering` 下沉到 `ObjCMetadataSource`，使 `ObjCDiffing` 不依赖渲染层。

### 非目标

- **不做注释化接口 diff**（`swift-section diff --interface` 的对应物）。它需要给
  `ObjCDeclarationRendering` 开 per-member 渲染 seam，工作量与本提案主体相当，且 change-list
  报告已覆盖核心需求。列为后续独立提案。
- **不纳入 C struct / union**。`ObjCInterfaceIndexer` 目前只暴露渲染结果
  （`structSemanticString(forName:context:)`），结构化字段数据是 private 的 `CStructOrUnion`；纳入
  需要先动 `ObjCIndexing` 的 public API。列为后续增量（届时只需新增容器 bucket 并 bump
  formatVersion）。
- **不做 rename 关联启发式**（同容器内 add + remove 配对提示）。参考实现同样未做。
- **不折入 ivar `offset` 与 class `instanceSize`**（理由见前期调研；layout 敏感的比对维度留作后续
  可选项）。
- **不做 MachOImage（运行时进程内）快照入口**。`ObjCAPISnapshotBuilder` 泛型于
  `ObjCMetadataSource`，image 模式理论可用，但 CLI 与测试首轮只覆盖 `MachOFile`。

## 详细设计

### 模块与依赖

```
ObjCDiffing  ←  ObjCDump（swift-objc-dump 的模型层）
             ←  ObjCMetadataSource（uniqueName 等派生扩展下沉后）
```

`ObjCDiffing` 不依赖 `ObjCIndexing` / `ObjCDeclarationRendering` / `ObjCInterface`——与参考实现
「SwiftDiffing 只依赖 SwiftDeclaration（纯模型），不碰渲染与索引」的干净度对齐。冻结入口接收
纯值 `ObjCAPIModule`，由上层组装：

```swift
// ObjCDiffing —— 纯传递结构，不持久化，不含 Mach-O 句柄
public struct ObjCAPIModule {
    public let classes: [ObjCClassInfo]        // 每类只含自身声明（info.first），不含超类链
    public let protocols: [ObjCProtocolInfo]
    public let categories: [ObjCCategoryInfo]
}

// ObjCInterface —— 索引器到模块的桥（与 SwiftDiffableInterfaceBuilder 的角色对应）
public struct ObjCAPISnapshotBuilder<MachO: ObjCMetadataSource> {
    public init(indexer: ObjCInterfaceIndexer<MachO>)   // 调用方先 prepare()
    public func module() -> ObjCAPIModule
    public func snapshot() -> ObjCAPISnapshot           // = ObjCAPIDiffer().snapshot(of: module())
}
```

类型统一带 `ObjC` 前缀（`ObjCMemberLineage` 而非 `MemberLineage`）：下游（如 RuntimeViewer）
会同时 import `SwiftDiffing` 与 `ObjCDiffing`，无前缀会与 `SwiftDiffing.MemberLineage` 等逐一
同名冲突，处处要写模块限定。

### 身份键与载荷键

```swift
/// A stable identity for one ObjC declaration or member. Unlike SwiftDiffing's
/// ABIKey there is no remangle and no fallback branch — ObjC identities are
/// plain names/selectors, total by construction.
public struct ObjCAPIKey: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: String
}
```

命名空间格局（`rawValue` 的事实格式，即持久化格式的一部分，变更必须 bump formatVersion）：

| 实体 | identityKey | payloadKey | signature（人读） |
|---|---|---|---|
| instance method | `method:-<selector>` | typeEncoding | `headerString`（`- (void)foo:(id)bar;`） |
| class method | `method:+<selector>` | typeEncoding | `headerString` |
| instance property | `property:-<name>` | attributes 序列化串，**剥除 `V`（backing ivar）**，折入 optionality | `headerString` |
| class property | `property:+<name>` | 同上 | `headerString` |
| ivar | `ivar:<name>` | typeEncoding（**不含 offset**） | `headerString` |
| protocol 采纳 | `adopts:<protocolName>` | = identityKey（只有 added / removed） | `adopts <protocolName>` |
| superclass（class 容器的伪成员） | `superclass` | `<superClassName>`（root class 为空串） | `superclass: <name>` |
| 容器：class | `class:<name>` | —（容器无 payload，成员递归 diff） | `<name>` |
| 容器：protocol | `protocol:<name>` | — | `<name>` |
| 容器：category | `category:<uniqueName>` | — | `<uniqueName>` |

语义要点：

- **method 的 identity 不含 typeEncoding**：selector 是 ObjC 的调用契约，同 selector 换编码是
  「同一入口的签名变化」，报 `modified`（old → new 并列显示）——这与 Swift 侧「function 换签名 =
  换 symbol = removed + added」刻意不同，因为 ObjC 的动态派发身份就是 selector 本身。
- **protocol 成员的 optionality 进 payload 不进 identity**：required ↔ optional 迁移报 `modified`。
- **superclass 作为伪成员**而非折入容器身份：类名是稳定身份，换父类应报「类被修改」并显示
  old → new，而不是整类 removed + added（参考实现把 struct↔class 折进容器身份是因为 Swift 的
  mangling 本来就含 kind；ObjC 无此约束，选可读性更好的一侧）。

### 快照模型与持久化

```swift
public enum ObjCContainerKind: Sendable, Codable, Equatable { case `class`, `protocol`, category }

public enum ObjCMemberKind: Sendable, Codable, Equatable {
    case instanceMethod, classMethod
    case instanceProperty, classProperty
    case ivar
    case protocolAdoption
    case superclass
}

public struct ObjCMemberRecord: Sendable, Codable, Equatable {
    public let identityKey: ObjCAPIKey
    public let payloadKey: ObjCAPIKey
    public let kind: ObjCMemberKind
    public let signature: String
    /// Protocol members only: whether the requirement is optional. Verdict
    /// metadata for the compatibility refinement, never part of the keys.
    public let isOptionalRequirement: Bool?
}

public struct ObjCContainerSnapshot: Sendable, Codable, Equatable {
    public let key: ObjCAPIKey
    public let name: String
    public let kind: ObjCContainerKind
    /// Category containers only: the extended class name, for reporting.
    public let targetClassName: String?
    public let members: [ObjCMemberRecord]
}

public struct ObjCAPISnapshot: Sendable, Codable, Equatable {
    public var classes: [ObjCContainerSnapshot]
    public var protocols: [ObjCContainerSnapshot]
    public var categories: [ObjCContainerSnapshot]
}

public struct ObjCAPIProvenance: Sendable, Codable, Equatable {
    public var label: String?
    public var binaryPath: String?
    public var generatorVersion: String?
    public var createdAt: Date?
}

public struct ObjCAPISnapshotDocument: Sendable, Codable, Equatable {
    public static let currentFormatVersion = 1
    public let formatVersion: Int          // 解码时严格校验，不符抛类型化错误
    public var provenance: ObjCAPIProvenance?
    public var snapshot: ObjCAPISnapshot
    public static func decode(from data: Data) throws -> ObjCAPISnapshotDocument
    public func encoded() throws -> Data   // ObjCAPIJSON：sortedKeys + prettyPrinted + ISO-8601
}
```

投影规则（`ObjCAPIDiffer.snapshot(of:)`，唯一接触 `*Info` 的地方）：

- class 容器成员 = `methods` + `classMethods` + `properties` + `classProperties` + `ivars` +
  `protocols.map(\.name)`（只取第一层，即直接采纳）+ superclass 伪成员。
- protocol 容器成员 = required 四组 + optional 四组（optionality 进 payload 与
  `isOptionalRequirement`）+ 直接引用协议的 `adopts:` 记录。
- category 容器成员 = 四组成员 + `adopts:` 记录（无 ivar、无 superclass）。

### Differ 与 Diff

```swift
public enum ObjCChangeStatus: Sendable, Codable, Equatable { case added, removed, modified }

public struct ObjCMemberChange: Sendable, Codable, Equatable {
    public let key: ObjCAPIKey
    public let kind: ObjCMemberKind
    public let status: ObjCChangeStatus
    public let oldSignature: String?
    public let newSignature: String?
    public let compatibilityOverride: ObjCCompatibility?
}

public struct ObjCContainerChange: Sendable, Codable, Equatable {
    public let key: ObjCAPIKey
    public let name: String
    public let containerKind: ObjCContainerKind
    public let status: ObjCChangeStatus
    public let memberChanges: [ObjCMemberChange]   // added/removed 容器为空，整容器即变更
}

public struct ObjCAPIDiff: Sendable, Codable, Equatable {
    public let classes: [ObjCContainerChange]
    public let protocols: [ObjCContainerChange]
    public let categories: [ObjCContainerChange]
    public let oldProvenance: ObjCAPIProvenance?
    public let newProvenance: ObjCAPIProvenance?
    public let diagnostics: ObjCAPIDiffDiagnostics?
    public var isEmpty: Bool { get }
}

public struct ObjCAPIDiffer: Sendable {
    public init()
    public func snapshot(of module: ObjCAPIModule) -> ObjCAPISnapshot
    public func diff(old: ObjCAPIModule, new: ObjCAPIModule) -> ObjCAPIDiff        // 冻结后走下面的入口
    public func diff(old: ObjCAPISnapshotDocument, new: ObjCAPISnapshotDocument) -> ObjCAPIDiff
    public func diff(old: ObjCAPISnapshot, new: ObjCAPISnapshot,
                     oldProvenance: ObjCAPIProvenance?, newProvenance: ObjCAPIProvenance?) -> ObjCAPIDiff
}
```

算法与参考实现逐点一致：`threeWayMatch`（identity 建索引，first-wins）分出 removed / added /
common，common 对比 `payloadKey` 决定 modified；容器级匹配后递归成员 diff；输出按
`(key, status)` 确定性排序。

### 兼容性判定

```swift
public enum ObjCCompatibility: Sendable, Codable, Equatable { case additive, breaking }
```

- 基线规则：added → additive；removed / modified → breaking；modified 容器 breaking 当且仅当
  存在 breaking 成员。
- refinement（`compatibilityOverride`）：protocol 容器内新增成员且 `isOptionalRequirement == false`
  → breaking（conformer 缺实现）；`== true` → additive。
- `ObjCAPIDiff.hasBreakingChange` / `.isBackwardCompatible`、
  `ObjCAPIEvolution.transitionCompatibilities` / `.firstBreakingVersionIndex` 与参考实现同构。
- **已知局限（文档化，不绕过）**：ivar 与 method 在 ObjC 里没有访问控制，无法从二进制区分
  「公开 API」与「私有实现」，判定把一切 removed / modified 都算 breaking——私有 selector 的重命名
  会被判 breaking，读者需自行结合语义判断。这与参考实现「@frozen 不可恢复，一律按 resilient
  处理」是同一类诚实取舍。

### Evolution

模型与算法完整移植（`ObjCAPIVersionDescriptor` / `ObjCLineageEvent` / `ObjCMemberLineage` /
`ObjCContainerLineage` / `ObjCAPIEvolution` / `ObjCAPIEvolutionBuilder` / `ObjCAPIEvolutionError`），
语义约定不变：事件 = 相邻转换；presence 位图含「移除后回归」；容器缺席的转换不枚举成员；
仅有事件的 lineage 才收录；N == 2 时与双侧 diff 一致（测试锁定）。bucket 为 classes / protocols /
categories 三个。

### 诊断

`ObjCAPIKeyCollision` + `ObjCAPIDiffDiagnostics` + `ObjCAPISnapshot.keyCollisions()`，first-wins 语义
与上浮路径（diff 逐侧、evolution 逐版本、reporter Warnings 段）照搬。不存在 remangle 回退维度。

### Reporter

`ObjCAPIDiffReporter`（`+` / `-` / `~` change-list）与 `ObjCAPIEvolutionReporter`（版本轴 + `●`/`○`
presence 位图 + 逐事件时间线），均为纯 `值 -> String` 函数，版式对齐参考实现。

### CLI

```
objc-section snapshot <binary> [--label 26.0] [MachOOptionGroup 全部选项] [-o baseline.json]
objc-section diff <old> <new> [--architecture …] [--dyld-shared-cache --cache-image-name …]
                  [--summary-only | --json] [--fail-on-breaking] [-o report.txt]
objc-section evolution <path>... [--labels 17.0,18.0,26.0] [同上加载选项]
                  [--summary-only | --json] [--fail-on-breaking] [-o report.txt]
```

- 每个输入既可是 Mach-O / fat 二进制 / dyld shared cache，也可是快照 JSON；嗅探规则（首个非空白
  字节 `{`）与加载、索引、冻结、provenance 盖章集中在 `Utilities/ObjCSnapshotInputLoader.swift`，
  三个命令共用，复用现有 `MachOFile.load(...)`。
- `snapshot` 与 `swift-section` 一致地拒绝 `--uses-system-dyld-shared-cache`（系统 cache 无稳定路径
  可记录）。
- 互斥校验（`--json` vs `--summary-only` 等）与 `swift-section` 逐条对齐。
- CLI 是本包对外契约的一部分（0002 的结论）：三个子命令名与 flag 拼写一经发布即冻结。

### 前置小重构：模型派生扩展下沉

`ObjCCategoryInfo.uniqueName`、`ObjCPropertyInfo.ivar` / `.customGetter` / `.customSetter` 从
`ObjCDeclarationRendering/ObjCDump+SemanticString.swift` 移至 `ObjCMetadataSource` 新文件
`ObjCDump+ModelDerivations.swift`。它们是纯模型派生（一行拼接 / attributes 查找），与渲染无关；
下沉后 `ObjCDiffing` 与 `ObjCDeclarationRendering` 共用一份，杜绝两处拼 `ClassName(CategoryName)`
漂移。

## 替代方案考量

- **给外部 `*Info` 类型加 retroactive `Codable`，直接序列化模型** —— 否。跨模块 retroactive
  conformance 在 Swift 6 有警告且属脆弱契约（上游加字段即破坏格式）；`protocols` 递归树直接序列化
  会指数膨胀；快照格式会被外部包的模型形状锁死，formatVersion 语义无从谈起。投影记录让持久化
  格式完全归本仓库所有。
- **把 diff 建在渲染文本上（比对 `headerString` / SemanticString 行）** —— 否。文本受
  `ObjCGenerationOptions` 与 transformer 干扰，且拿不到 modified 语义（动机一节的三条弊端）。
- **复用 `ObjCInterfaceBuilder` 的 strip 语义（比对「过滤后」的模型）** —— 否。strip（剥合成访问器
  等）是渲染视图的关切；diff 的对象是「二进制里的 metadata 事实」，快照应与渲染选项无关，否则
  同一二进制在不同选项下产出不同 baseline，格式失去意义。合成访问器与 property 的变化同时上报
  属于如实反映 metadata，不是重复噪声。
- **无前缀类型名（模块限定消歧）** —— 否。下游会同时 import 两个 diffing 库，十余个类型逐一同名，
  处处 `SwiftDiffing.MemberLineage` / `ObjCDiffing.MemberLineage` 的代价远高于前缀。
- **method 换 typeEncoding 报 removed + added（对齐 Swift 侧 function 语义）** —— 否。Swift 侧那样做
  是因为 mangled symbol 就是 ABI 入口点，换签名确实是新符号；ObjC 的入口点是 selector，编码变化
  是同一入口的属性变化，modified（old → new 并列）信息量更大。
- **把 superclass / instanceSize 折入 class 容器身份** —— 否。换父类报整类 removed + added 会淹没
  「该类其余成员并未变化」这一信息；instanceSize 是 ivar 布局的派生值，纯噪声。
- **单独 target 还是并入 `ObjCInterface`** —— 单独。`ObjCInterface` 依赖渲染与索引两层，并入会让
  纯值计算背上不需要的依赖；参考实现同样是独立模块。

## 影响

### 源码兼容性（source compatibility）

- 主体为**纯新增**：新 target `ObjCDiffing` 与新 product，`ObjCInterface` 新增
  `ObjCAPISnapshotBuilder`，CLI 新增三个子命令，均不触碰现有 API。
- **一处潜在破坏**：四个派生 extension 从 `ObjCDeclarationRendering` 移到 `ObjCMetadataSource`。
  Swift 的 extension 可见性随定义模块走——下游若 `import ObjCDeclarationRendering` 使用
  `uniqueName` 而未 import `ObjCMetadataSource`（它是前者的依赖，通常已间接引入但仍需显式
  import），需补一行 import。仓库内的使用点（`ObjCIndexing` / `ObjCInterface` / CLI）在同批次修正。
  不提供 deprecation 过渡：这是声明位置迁移，旧位置无法保留同名声明（会构成重复定义）。

### ABI 兼容性（条件项）

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- 仓库内：`ObjCMetadataSource`（+派生扩展）、`ObjCDeclarationRendering`（−派生扩展）、
  `ObjCInterface`（+builder）、`objc-section`（+3 子命令）、`Package.swift`（+target/product）。
- 跨仓库：RuntimeViewer 等同时消费两库的下游若使用了 `uniqueName` 派生扩展需补 import；
  其余为纯新增能力，可按需采用。

### 文档与示例

- `README.md`（英文，对外）：新增 `ObjCDiffing` product 与三个子命令的用法示例。
- `Documentations/Guides/ObjCSectionCommandLine.md`：补三个子命令；baseline 的 formatVersion
  契约（键格局即持久化格式，工具版本不符时旧 baseline 显式失效）写进指南。
- 新增 `Documentations/Internal/ObjCAPIDiffDesignAndLimitations.md`：设计取舍与已知局限
  （无访问控制之别、ivar offset 不折入、与 SwiftDiffing 的语义差异对照表）。
- `Documentations/Glossary.md`（如尚不存在则新建）：登记 identity key / payload key / lineage /
  provenance / baseline 等术语，与 MachOSwiftSection 侧同名概念互链。

## API 演进与废弃策略

- 无被替代的旧 API；派生扩展迁移不保留旧位置（见源码兼容性）。
- 版本号：minor bump（0.x 阶段的纯新增 + 一处迁移）。
- `ObjCAPISnapshotDocument.currentFormatVersion` 自 1 起：**任何键格局或 record 字段变更都必须
  bump**，让旧 baseline 显式失效而非被静默误读——这是与参考实现相同的持久化纪律。

## 落地步骤

1. 前置重构：派生扩展下沉 `ObjCMetadataSource`，仓库内 import 修正；全量测试过。
2. `ObjCDiffing` 核心：`ObjCAPIKey` / `ObjCMemberRecord`（含全部投影规则）/ `ObjCAPISnapshot` /
   `ObjCAPIModule` / `ObjCAPIDiffer` / `ObjCAPIDiff` / `ObjCCompatibility` / 诊断通道 +
   `ObjCDiffingTests`（纯值构造：投影、三路匹配、payload 变更、optionality refinement、键碰撞、
   排序确定性）。
3. 持久化：`ObjCAPIProvenance` / `ObjCAPISnapshotDocument` / `ObjCAPIJSON` + codec 测试
   （round-trip、缺版本头、版本不符、字节稳定）。
4. Evolution：模型 + builder + 测试（presence 位图、移除后回归、容器缺口语义、N == 2 与双侧
   diff 一致性、标签解析、逐转换兼容性）。
5. 两个 reporter + 整段文本断言测试。
6. `ObjCInterface.ObjCAPISnapshotBuilder` + 进程内 image fixture 的冒烟测试。
7. CLI：`SnapshotCommand` / `DiffCommand` / `EvolutionCommand` + `ObjCSnapshotInputLoader` +
   `ObjCSectionCommandTests` 解析测试；真实二进制手工验证（两个 OS 版本的同一框架）。
8. 文档同批次：README / CLI 指南 / Internal 设计文档 / Glossary / 本提案状态推进。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 已预判需要：使用指南（baseline formatVersion 契约）与实现说明
  （设计取舍与局限），见「文档与示例」。
- **有没有引入新术语** —— 已预判需要：见「文档与示例」的 Glossary 条目。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-20 | Created as Draft | 用户提出实现 Diff 与 Evolution 新需求，参照 MachOSwiftSection 已落地的 SwiftDiffing API；完成两侧调研后成稿 |
| 2026-08-20 | Draft → Accepted | 用户批准，未要求修改 |
| 2026-08-20 | Accepted → In Progress | 按落地步骤开始实现 |
| 2026-08-20 | In Progress → Implemented | 全部八步落地：`ObjCDiffing`（13 文件）+ `ObjCAPISnapshotBuilder` + CLI 三命令；新增 57 个测试全绿（45 纯值 + 3 冒烟 + 9 CLI 解析），既有 swift-testing 套件无回归；真实验证 macOS 15.5 vs 26.5.2 dyld cache 的 CoreLocation（diff 644 行报告、evolution 摘要、`--fail-on-breaking` 退出码正确）。收尾两判断：**配套文章**——需要，已写实现说明并扩写 CLI 指南（见头部「配套文档」）；**新术语**——有，key namespace / pseudo-member / uniqueName / ObjCAPIModule-vs-Snapshot 登记项目术语表，baseline snapshot / identity-payload key / lineage 三条跨项目术语登记全局术语表 |
