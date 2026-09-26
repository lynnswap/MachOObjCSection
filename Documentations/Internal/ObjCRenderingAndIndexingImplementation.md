# ObjC 渲染层与索引层的实现说明

- **对应提案**: [0001](../Evolutions/0001-objc-rendering-and-indexing-downstreaming.md)
- **后续订正**: [0005](../Evolutions/0005-adopt-frameworktoolbox-utilities.md) 推翻了 0001 关于
  Linux 与 FrameworkToolbox 的两条判断，本文相应两节已更新
- **最后更新**: 2026-08-14

这份文档记录 0001 落地过程中那些**从代码本身看不出来**的决策：为什么某条看起来更简单的路走不通，
以及哪些地方与提案的设想不一致。提案是决策快照，保持原貌；实际实现的偏差记在这里。

## 分层与依赖方向

```
MachOObjCSection          纯解析，未改动
        ↑
ObjCDeclarationRendering  ObjC*Info → SemanticString；ObjCGenerationOptions 也在这一层
        ↑
ObjCIndexing              索引；继承/遵守关系只经事件广播（见 0003）
        ↑
ObjCInterface             strip 过滤 + 渲染编排入口
```

### 为什么 `ObjCGenerationOptions` 在渲染层，而不是提案说的 `ObjCInterface`

提案把 `ObjCGenerationOptions` 归到第 6 步的 `ObjCInterface`。实际落地时发现这会**依赖倒挂**：

十个开关里有四个是「加注释」类（`addIvarOffsetComments`、`addPropertyAttributesComments`、
`addMethodIMPAddressComments`、`addPropertyAccessorAddressComments`），它们是在**渲染时**读取的
（`ObjCRenderingContext.options`），也就是说渲染层必须能看见这个类型。而依赖方向是
`ObjCInterface → ObjCDeclarationRendering`，把它放在 `ObjCInterface` 会让底层反过来依赖上层。

因此 `ObjCGenerationOptions` 落在 `ObjCDeclarationRendering`。`ObjCInterface` 仍然是唯一
**执行** strip 那六个开关的地方 —— 类型的归属和职责的归属在这里是分开的。

### 具体 transformer 最终不在 `swift-semantic-string` 里

提案的方案是把整个 `OutputTransformer` 并进 `swift-semantic-string`。落地后调整为：
**那个包只留 `Transformer` 命名空间和 `Module` 协议，具体模块跟着各自的领域走。**

| 模块 | 归属 |
|---|---|
| `SwiftFieldOffset` / `SwiftVTableOffset` / `SwiftMemberAddress` / `SwiftTypeLayout` / `SwiftEnumLayout` / `SwiftConfiguration` | MachOSwiftSection 的 `SwiftOutputTransformer` |
| `CType` / `ObjCIvarOffset` / `ObjCConfiguration` | MachOObjCSection 的 `ObjCOutputTransformer` |
| 聚合 `Configuration` | RuntimeViewerCore |

理由正是提案自己用来否决「并进 `Semantic` target」的那一条：`bitsNeededForTag`、
`payloadRegionBytesHex` 这些 token 名字带着强烈的领域语义。提案当时只把它推到「不进
`Semantic`，但仍在同一个仓库」，现在推到底 —— 一个通用字符串包不该携带任何一方的词汇表。

**为什么命名空间还留在通用包里**：如果两边各自定义 `public enum Transformer`，RuntimeViewer
同时 import 两侧时 `Transformer.CType` 就会歧义，必须写成 `ObjCOutputTransformer.Transformer.CType`。
留一个 51 行的共享骨架，两边都 `extension Transformer`，调用点一个字都不用改。

聚合 `Configuration` 落在 RuntimeViewerCore，是因为它是唯一横跨两半的类型，而查证下来
它的使用者（settings 持久化、导出元数据、`ContentTextViewModel`）**全部**在 RuntimeViewer。

### 为什么渲染层不直接依赖 `OutputTransformer`

`ObjCRenderingContext` 接的是两个「纯数据」而不是两个 transformer 对象：

```swift
public var cTypeReplacements: [ObjCPrimitiveTypePattern: String]
public var ivarOffsetCommentBuilder: (@Sendable (Int) -> String)?
```

看起来更简单的做法是直接吃 `Transformer.CType` 和 `Transformer.ObjCIvarOffset`，省掉
`ObjCPrimitiveTypePattern` 这个与 `Transformer.CType.Pattern` 同形的枚举。不这么做的理由：

**渲染只需要「查一张替换表」和「拿一个字符串」，不需要知道那张表是怎么来的。** 让渲染层依赖
`OutputTransformer`，等于强迫每个只想拿一段 `@interface` 的库使用者一并拉进一个模板引擎，
并去理解 token 占位符这套机制。转换的成本只在调用点一次 `reduce`（见
`RuntimeObjCSection.interface(for:using:transformer:)`），由**用了**模板的那一方承担，这是对的。

`ObjCPrimitiveTypePattern` 与 `Transformer.CType.Pattern` 的 `rawValue` 保持一致，
调用点按 `rawValue` 转换即可。**两边的 case 必须同步增删**，这是这个决策唯一的持续成本。

## Linux 支持：真正的障碍是什么

提案判断「3 处 `@AssociatedObject` 底层是 `objc_setAssociatedObject`，Linux 不可用」，
据此要求把它们换成 `WeakKeyStrongValueMap` 思路的实现。**这个判断是错的，实现时已撤销。**

- `p-x9/AssociatedObject` 的 `Package.swift` 对 `.linux/.openbsd/.windows/.android`
  条件依赖 `swift-object-association`，`functions.swift` 里有
  `#if canImport(ObjectiveC) … #elseif canImport(ObjectAssociation)` 的分支；
- 它的 C 部分 `AssociatedObjectC` 只用 `__builtin_return_address(0)` 生成 key，
  带 GCC / MSVC / wasm 分支，平台无关。

三处 `@AssociatedObject` 因此**原样保留**，`MachOKitExtensions` 的源码零改动。

真正挡住 Linux 的是 **`FoundationToolbox`**（`Mx-Iris/FrameworkToolbox`）：它的 `platforms`
只列 Apple 平台，且 `String.lastPathComponent` 之类是走 `NSString` 桥接实现的。
`MachOKitExtensions` 只用到它三处小东西，全部改写成标准库调用：

| 原写法 | 改后 | 位置 |
|---|---|---|
| `ptr.bitPattern.int` | `Int(bitPattern: ptr)` | `MachORepresentableWithCache.swift`、`LocatableLayoutWrapper.swift` |
| `box.bitPattern.uint.uint64` | `UInt64(UInt(bitPattern: self))` | `MachORepresentableWithCache+.swift` |
| `imagePath.lastPathComponent.deletingPathExtension` | `URL(fileURLWithPath:).deletingPathExtension().lastPathComponent` | `DyldCache+.swift` |

**注意这两组语义不同**，改写时必须分辨：`FrameworkToolbox` 里 `.box.int` 是**值转换**
（`Int.init(_:)`，溢出会 trap），`.box.bitPattern.int` 是**位模式转换**
（`Int.init(bitPattern:)`）。上表全部属于后者。

### 订正（0005）：这个改写没有保住 Linux

上面这段推理是对的，**结论是错的** —— 同一个 `FoundationToolbox` 从另一条边进来了：

```
MachOObjCSection ──> ObjCDump ──> ObjCTypeDecodeKit ──> FoundationToolbox
```

`swift-objc-dump` 自 `cab0d68`（2026-01-03）起就依赖它，也就是说 0001 落地时这条边已经存在。
`FoundationToolbox` 的 Keychain 三个文件无条件 `import Security`，所以**本库在 Linux 上从
0001 之前就构建不过**，把 `MachOKitExtensions` 里那三处改写成标准库并没有保住任何东西。

改写本身**保留不回退** —— 标准库调用等价且更直接，少一个依赖也不是坏事。要恢复 Linux，
前置条件是让 `swift-objc-dump` 摘掉 `FoundationToolbox`，那是另一个仓库的事。

这次核对漏掉 `ObjCDump` 这条边的教训：**判断一个依赖在不在图里，看 `Package.resolved`，
不要只顺着自己直接声明的那几条边推**。`frameworktoolbox` 在那份文件里一直躺着。

没有在**不加同名 public 扩展**上让步：曾考虑在 `MachOKitExtensions` 里补一套同形的
`String.lastPathComponent` / `UnsafeRawPointer.bitPattern`，让源码一行不改。放弃了 ——
MachOSwiftSection 同时 import `MachOKitExtensions` 和 `FoundationToolbox`，同名 public 扩展会产生歧义。

### 抽包的连带代价

`MachOKitExtensions` 从 MachOSwiftSection 的内部 target 变成外部包后，出现了两类新问题：

1. **一处源码不再能隐式拿到 `FoundationToolbox`**。
   `MachOReading/Readable/UnsafeRawPointer+Readable.swift` 用了 `box.bitPattern.int`
   却没有 `import FoundationToolbox` —— 此前靠同包 target 之间的传递可见性才编译得过。
   已补上显式 import。提案说的「MachOSwiftSection 源码零改动」在这一处不成立。
2. **retroactive conformance 警告**。`MachONamespacing` 现在是外部协议，
   `extension FileHandle: MachONamespacing {}` 之类会警告
   「this will not behave correctly if the owners of Foundation introduce this conformance」。
   加 `@retroactive` 即可消除，本轮未做（不影响构建，且属于 MachOSwiftSection 的清理）。

## `ObjCIndexing` 的锁

**现状（0005 之后）**：五个存储直接用 `FrameworkToolbox` 的 `@Mutex` 宏，
`ObjCIndexing` 依赖 `SwiftStdlibToolbox`。

```swift
@Mutex
private var classes: [String: ObjCClassGroup] = [:]
```

0001 当初判断这个宏「Apple-only 而本包支持 Linux」，自封了一份 `NSLock` 版
`Internal/Mutex.swift`。**两条理由都不成立**，见上一节的订正与 0005。

选宏而不是继续手写「盒子 + 计算属性」，关键在宏多生成一个 `_modify`：

```swift
_modify {
    let valuePointer = _classes._unsafeLock()
    defer { _classes._unsafeUnlock() }
    yield &valuePointer.pointee
}
```

只有 get/set 的版本里，`classes[name] = group` 会展开成 get → 改副本 → set，两次独立取锁，
中间敞开；有了 `_modify` 就是一次持锁的读-改-写。今天走查是单线程的所以看不出差别，
但索引器是 `@unchecked Sendable` 且并行化写在 `eventHandler` 的文档里。

**代价是 `os_unfair_lock` 不可重入**：`_modify` 的 `yield` 期间锁持着，此时再访问同一个属性
会死锁（旧的 get/set 版本只会读到旧值）。现在每处访问都是「取一个 key / 写一个 key」的直筒
形状，没有嵌套 —— 加访问点时要守住这条。

顺带订正 0001 的一句话：它说这个双份形状不能简化，因为有些地方直接 `_classes.withLock { … }`
做读-改-写。**那些调用点是关系反向表，0003 已经整体移出本库**，现在 `_classes` 只被它自己的
访问器用到。

### 落地时撞到的一个坑

`SwiftStdlibToolbox` 的 `Mutex` 与本地 `Internal/Mutex.swift` 同名，而**同模块内的类型优先于
导入的类型**。所以只加 `import` 不删本地文件时，宏展开里的 `Mutex` 仍解析到本地那个
`final class`，报的错是

```
value of type 'Mutex<...>' has no member '_unsafeLock'
```

—— 看起来像宏坏了，实际是名字撞了。**先删本地文件，再改用宏**。

## 事件通道：两条合并成一条

RuntimeViewer 原来有两条并行通道：`AsyncThrowingStream` 的进度 continuation，
和一个 `RuntimeObjCInterfaceEvents.Handler` 关系事件回调。两者都由同一趟
`__objc_classlist` 遍历驱动，调用方要同时接两个东西并自己保持同步。

现在统一为 `ObjCIndexingEvent` 一条：`.progress` 加三个关系 case。

RuntimeViewer 侧在 `RuntimeObjCSection.makeEventHandler(forwardingTo:)` 里把 `.progress`
适配回 `RuntimeObjectsLoadingEvent`。

> **本节关于关系事件的结论已被 [0003](../Evolutions/0003-objc-relationship-tables-return-to-application.md) 推翻。**
> 这里原本写的是「关系事件不需要转发 —— 它们的结果已经落在索引器自己的反向表里，
> `RuntimeRelationshipsResolver` 直接查表」。0003 把反向表移出了本库：索引器不再存任何关系，
> 三个关系事件成了关系数据**唯一**的出口，消费者必须转发并自行建表。没装 handler 的索引器
> 不保留任何继承 / 遵守信息，且完全静默。
>
> 连带的另一处反转：当时的合并把两条通道并成一条是为了让调用方少接一个东西；0003 之后
> handler 从「可选的观察者」变成了「必需的数据通道」，`eventHandler` 传 `nil` 不再是
> 「不关心进度」，而是「放弃关系数据」。

phase 名去掉了 `ObjC` 前缀（`.indexingObjCSubclasses` → `.indexingSubclasses`）：库只索引 ObjC，
不必再限定；而 RuntimeViewer 的 `RuntimeObjectsLoadingProgress.Phase` 横跨 ObjC 与 Swift 两半，
保留前缀才不歧义。映射表在 `Core/ObjCIndexingEvent+LoadingProgress.swift`。

## 已知遗留：setter 选择器少一个冒号

`ObjCInterfaceBuilder` 里 `stripSynthesizedMethods` 收集要剥掉的 setter 时用的是：

```swift
let setterName = property.customSetter ?? "set" + propertyName.uppercasedFirst   // 无冒号
```

而渲染层查 IMP 地址时用的是：

```swift
let setterName = customSetter ?? "set\(name.uppercasedFirst):"                    // 有冒号
```

真实的 ObjC 选择器是 `setFoo:`（有冒号），所以 **strip 那一处大概率匹配不上，
`stripSynthesizedMethods` 实际上剥不掉 setter，只剥得掉 getter**。

这是**从 RuntimeViewerCore 原样迁移过来的既有行为，不是本轮引入的**。本轮刻意没有「顺手修」：
提案的验收标准是输出与迁移前逐字符一致，改掉它会让所有开着这个开关的输出发生变化，
属于行为变更，应当单独提案并配回归测试。

## 与提案的差异汇总

| 提案怎么说 | 实际怎么做 | 原因 |
|---|---|---|
| 3 处 `@AssociatedObject` 换成非 ObjC-runtime 实现 | 原样保留 | 该库本身已支持 Linux，提案的归因有误 |
| （未提及 `FoundationToolbox`） | 去掉该依赖，3 处改写成标准库调用 | 当时认为它才是真正阻断 Linux 的那个。**0005 订正**：`ObjCDump` 从另一条边把它带了回来，改写没有保住 Linux（改写本身保留） |
| MachOSwiftSection 源码零改动 | 改了 1 个文件（补 1 行 import） | 抽包后传递可见性断掉 |
| `ObjCGenerationOptions` 放 `ObjCInterface` | 放 `ObjCDeclarationRendering` | 否则依赖倒挂 |
| 新仓库位于 `/Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/` | 位于 `/Volumes/Code/Personal/` | 提案写的路径在本机不存在，与其余仓库同放一处 |
| 新仓库定名 `MachOExtensions` | 定名 `MachOKitExtensions` | `MachOExtensions` 读起来像是给「MachO」模块写的扩展，而它扩展的是 `MachOKit` 这个库。提案正文保留原名作为决策快照，以决策日志末条为准 |
| 整个 `OutputTransformer` 并入 `swift-semantic-string` | 只并入命名空间与 `Module` 协议；具体模块分别落到 `SwiftOutputTransformer`（MachOSwiftSection）与 `ObjCOutputTransformer`（MachOObjCSection），聚合 `Configuration` 落到 RuntimeViewerCore | 通用字符串包不该携带任一方的领域词汇表。命名空间留在通用包是硬需求，否则两边同名 `Transformer` 在 RuntimeViewer 里歧义 |

## 验证边界

- **Linux 未实测**：本机无 Docker，无法真正跑 Linux 构建。已做的是静态核对 ——
  `MachOKitExtensions` 与三个新 target 的源码不含任何 Darwin-only API，
  依赖链（MachOKit / AssociatedObject / Semantic / OrderedCollections）均声明支持 Linux。
  **0005 订正**：这次核对只顺着直接声明的依赖边走，漏了 `ObjCDump → ObjCTypeDecodeKit →
  FoundationToolbox`，结论因此是错的 —— 本库在 Linux 上构建不过。
- **远程依赖未验证**：`MachOKitExtensions` 尚未推送到 GitHub，`swift-semantic-string` 的
  `0.3.0` 尚未打 tag。所有构建均在 `USING_LOCAL_DEPENDENCIES=1` 下完成；
  远程模式要等仓库推送并打 tag 后才能验证。
- **MachOSwiftSection 的 Xcode fixture 测试跑不了**：`XcodeMachOFileName.swift` 硬编码
  `/Applications/Xcode-26.4.0.app/`，本机没有该版本，`glob` 落空即 `fatalError`。
  这是先前就存在的环境依赖，与本轮无关。
