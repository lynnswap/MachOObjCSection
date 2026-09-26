# 0005 - 改用 FrameworkToolbox 的 Mutex 与字符串工具，删掉本地手搓的副本

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-13
- **最后更新**: 2026-08-14
- **所属愿景**: 无
- **关联提案**: [0001](0001-objc-rendering-and-indexing-downstreaming.md)（它当初决定「不引入 FrameworkToolbox」，本提案推翻该决定）
- **实现分支 / PR**: main
- **配套文档**: 修订 [ObjC 渲染层与索引层的实现说明](../Internal/ObjCRenderingAndIndexingImplementation.md)

## 摘要

0001 出于「引入宏包不划算」与「保住 Linux」两条理由，在 `ObjCIndexing` 和
`ObjCDeclarationRendering` 里各自手搓了一份 `Mutex` 和 `uppercasedFirst` /
`lowercasedFirst`，`ObjCInterface` 还把 `uppercasedFirst` 又抄了一遍。

**这两条理由今天都不成立**：

1. `FrameworkToolbox` **早就在依赖图里** —— `swift-objc-dump` 的 `ObjCTypeDecodeKit`
   自 2026-01-03 起依赖 `FoundationToolbox`，而本库的 `MachOObjCSection` target 依赖
   `ObjCDump`。`Package.resolved` 里 `frameworktoolbox 0.9.0` 与 `swift-syntax 603.0.2`
   都已经在解析并编译，宏插件也已经在构建。直接依赖它的**边际成本是零**。
2. 同一条链条也意味着 **Linux 早就不通了** —— `FoundationToolbox` 的 Keychain 三个文件
   无条件 `import Security`。0001 为保住 Linux 而把 `MachOKitExtensions` 里三处
   `FoundationToolbox` 调用改写成标准库，实际上什么也没保住。

因此：加一条对 `FrameworkToolbox` 的直接依赖，删掉本地的 `Mutex.swift`、两份
`uppercasedFirst` 和一份 `lowercasedFirst`，改用上游的 `@Mutex` 宏与
`.box.uppercasedFirst()`。FrameworkToolbox 里**没有**对应物的那几个小工具
（`orEmpty`、`removingAll(where:)`、`Set.insert(contentsOf:)`、`OffsetEnumeratedSequence`）
原样留在本地。

## 动机

### 一、0001 的两条理由，今天一条都不成立

0001 的取舍表里有这么一行：

| 要用的东西 | 出处 | 0001 的判断 |
|---|---|---|
| `@Mutex`、`uppercasedFirst`、`orEmpty`、`removingAll` | `FrameworkToolbox` / `SwiftStdlibToolbox` | 宏包，为几个小工具引入不划算 |

「不划算」的前提是**引入它要付出新的解析与编译成本**。这个前提是错的，而且在 0001 落地时
（2026-08-09/10）就已经是错的 —— `swift-objc-dump` 在 `cab0d68`（2026-01-03，`Improve apis`）
就把 `FoundationToolbox` 加进了 `ObjCTypeDecodeKit`。依赖链是：

```
MachOObjCSection ──> ObjCDump ──> ObjCTypeDecodeKit ──> FoundationToolbox
                                                            │
                                                            └──> SwiftStdlibToolbox ──> FrameworkToolbox
                                                                                             │
                                                                                             └──> swift-syntax（宏插件）
```

`Package.resolved` 可以直接验证：`frameworktoolbox 0.9.0`、`swift-syntax 603.0.2` 都在里面。
`FoundationToolbox` 依赖 `FoundationToolboxMacros`（一个 `.macro` target），所以
**swift-syntax 与宏插件今天就在编译**。加一条 `.package(url: .../FrameworkToolbox)` 之后，
解析图不变、编译量不变，只是多了几个可以 `import` 的 product 名字。

### 二、Linux 早就断了，0001 为它做的适配没保住任何东西

0001 的实现说明里有一节「Linux 支持：真正的障碍是什么」，结论是
`FoundationToolbox` 是 Apple-only，因此把 `MachOKitExtensions` 里三处调用改写成标准库。

**这个改写没有意义** —— 同一个 `FoundationToolbox` 通过 `ObjCDump` 进来了，而且是本库最核心
target 的直接依赖，绕不过去。具体证据：

- `Sources/FoundationToolbox/Keychain/KeychainError.swift`、`KeychainStorage.swift`、
  `KeychainAccessibility.swift` 三个文件**无条件** `import Security`；
- `FrameworkToolbox` 的 `platforms:` 只列 Apple 平台。

也就是说，本库**今天在 Linux 上就构建不过**。0001 的实现说明里写着「Linux 未实测：本机无
Docker，无法真正跑 Linux 构建，已做的是静态核对」—— 那次静态核对漏掉了 `ObjCDump` 这条边。

本提案不是「放弃 Linux」，而是**承认它已经不在了**，并把三处基于它写的注释订正掉。真要恢复
Linux，前置条件是让 `swift-objc-dump` 摘掉 `FoundationToolbox`，那是另一个仓库、另一份提案。

### 三、`uppercasedFirst` 已经被抄了两份

`Sources/ObjCDeclarationRendering/Internal/String+Utilities.swift` 和
`Sources/ObjCInterface/Internal/Collection+Utilities.swift` 里各有一份逐字相同的
`uppercasedFirst`，连文档注释都近乎一致。原因是它们是 `internal`，跨 target 看不见。
每多一个需要它的 target，就要再抄一份 —— 这是「不引入依赖」这条路的持续成本，且只会变大。

### 四、`@Mutex` 的 `_modify` 修掉一个当前无害但真实的原子性缺口

现在五个存储都是「`Mutex` 盒子 + 只有 get/set 的计算属性」：

```swift
private let _classes = Mutex<[String: ObjCClassGroup]>([:])
private var classes: [String: ObjCClassGroup] {
    get { _classes.withLock { $0 } }
    set { _classes.withLock { $0 = newValue } }
}
```

这个形状下，`classes[name] = group` 会展开成 **get → 改副本 → set** 三步，两次独立取锁，
中间是敞开的。上游 `@Mutex` 宏额外生成一个 `_modify`：

```swift
_modify {
    let valuePointer = _classes._unsafeLock()
    defer { _classes._unsafeUnlock() }
    yield &valuePointer.pointee
}
```

于是同一句下标赋值变成**一次持锁的读-改-写**。

今天这不会出错 —— `prepare()` 的走查是单线程的。但 `ObjCInterfaceIndexer` 声明成
`@unchecked Sendable`，且它的 `eventHandler` 文档明确写着「今天的走查是单线程的，但那是当前
实现而非承诺，`@Sendable` 就是为了以后能并行化」。既然并行化是写进文档的方向，那么现在这个
非原子的下标赋值就是一颗已经埋好的雷。换成宏之后它自动消失。

顺带一提，0001 的实现说明称这个「盒子 + 计算属性」的双份形状不能简化，因为「有些地方直接用
`_classes.withLock { … }` 做读-改-写」。**那个理由今天已经不存在** —— 0003 把关系反向表
（`_subclassesByClassName` 等，正是那些直接 `withLock` 的调用点）整体移出了本库。现在
`grep '_classes\.'` 只能命中它自己的 get/set 两行。

## 前期调研

### FrameworkToolbox 里有什么、没有什么

| 本地手搓 | 位置 | 上游有对应物吗 |
|---|---|---|
| `final class Mutex` + `withLock` | `ObjCIndexing/Internal/Mutex.swift` | **有** —— `SwiftStdlibToolbox.Mutex`（`~Copyable` struct，`os_unfair_lock`）与 `@Mutex` 宏 |
| `String.uppercasedFirst` | `ObjCDeclarationRendering/Internal/String+Utilities.swift` | **有** —— `FoundationToolbox` 的 `.box.uppercasedFirst()` |
| `String.lowercasedFirst` | 同上 | **有** —— `.box.lowercasedFirst()` |
| `String.uppercasedFirst`（重复） | `ObjCInterface/Internal/Collection+Utilities.swift` | 同上 |
| `Optional.orEmpty` | `ObjCIndexing/Internal/Optional+Utilities.swift` | **没有** |
| `RangeReplaceableCollection.removingAll(where:)` | `ObjCInterface/Internal/Collection+Utilities.swift` | **没有** |
| `Set.insert(contentsOf:)` | 同上 | **没有** |
| `OffsetEnumeratedSequence` | `ObjCDeclarationRendering/Internal/` | **没有** |

上游的 `uppercasedFirst()` 语义与本地版一致（`base.prefix(1).uppercased() + base.dropFirst()`，
不动首字符以外的部分），`FoundationToolboxTests/StringExtensionTests.swift` 里有对应测试
（`#expect("hello".box.uppercasedFirst() == "Hello")`）。本地版文档注释里那条
「不能用 `capitalized`，它会把 `URLString` 的后半截压小写」的理由，上游实现同样满足。

### 该依赖哪个 product —— 不能是 `OSToolbox`

FrameworkToolbox 的本地 HEAD（`0.9.0-11-gd781e92`）把 `Mutex` / `@Loggable` 拆进了一个新的
`OSToolbox` product，但**这个拆分尚未发布** —— 已发布的 `0.9.0` tag 里 `Mutex` 和 `@Mutex`
仍在 `SwiftStdlibToolbox`，产品列表里根本没有 `OSToolbox`。

所以：

- `@Mutex` 走 **`SwiftStdlibToolbox`**。它在 0.9.0 里是宏的实际所在地，在 HEAD 之后的版本里
  `@_exported import OSToolbox`（上游 `Package.swift` 的注释明确写了这是为了让
  `import SwiftStdlibToolbox` 的老调用点继续能解析 `@Mutex`）。两个方向都成立。
- `uppercasedFirst()` 走 **`FoundationToolbox`**。它 `@_exported import SwiftStdlibToolbox`，
  所以同时也带来 `@Mutex`。

版本下限取 `from: "0.9.0"`（与 `Package.resolved` 里已解析的版本一致）。

### 平台下限相容

| | macOS | iOS | watchOS | tvOS |
|---|---|---|---|---|
| MachOObjCSection | 10.15 | 13 | 6 | 13 |
| FrameworkToolbox | 10.15 | 13 | 6 | 13 |

完全一致，不抬高任何平台的下限。

### `Mutex` 是 `#if canImport(os)` 包起来的

上游 `Mutex.swift` 整个文件在 `#if canImport(os)` 里，`@Mutex` 宏声明同理。这意味着采用它
**会把「Linux 上没有锁」变成一个编译期硬事实**，而不是像现在这样看起来还能编。

如「动机二」所述，本库在 Linux 上今天就构建不过，所以这不构成新的能力损失 —— 但它把这件事
从「注释里写着支持、实际不支持」变成「编译器直接说不支持」，反而更诚实。

## 提议方案

### 一、Package.swift 加一条直接依赖

```swift
.package(
    local: .package(path: "../FrameworkToolbox", isRelative: true),
    remote: .package(
        url: "https://github.com/Mx-Iris/FrameworkToolbox",
        from: "0.9.0"
    )
),
```

按本仓库既有的 `local:` / `remote:` 双形式写（与 MachOKit、swift-objc-dump 等一致），
本机开发时可走 `../FrameworkToolbox`。

三个 target 各加一个 product：

| target | product | 为了什么 |
|---|---|---|
| `ObjCIndexing` | `SwiftStdlibToolbox` | `@Mutex` |
| `ObjCDeclarationRendering` | `FoundationToolbox` | `uppercasedFirst()` / `lowercasedFirst()` |
| `ObjCInterface` | `FoundationToolbox` | `uppercasedFirst()` |

### 二、删除三处本地实现

- 删 `Sources/ObjCIndexing/Internal/Mutex.swift`（整个文件）
- 删 `Sources/ObjCDeclarationRendering/Internal/String+Utilities.swift`（整个文件）
- 删 `Sources/ObjCInterface/Internal/Collection+Utilities.swift` 里的 `extension String`
  （文件本身保留 —— `removingAll(where:)` 和 `Set.insert(contentsOf:)` 上游没有）

### 三、五个存储改用 `@Mutex`

```swift
@Mutex
private var classes: [String: ObjCClassGroup] = [:]
```

五处同形，`protocols` / `categories` / `structs` / `unions` 一样。宏生成的存储名恰好也是
`_classes`，与现在的手写形状一致。

### 四、四个调用点改成 `.box.` 形式

| 文件 | 改前 | 改后 |
|---|---|---|
| `ObjCInterface/ObjCInterfaceBuilder.swift:350` | `"set\(propertyName.uppercasedFirst):"` | `"set\(propertyName.box.uppercasedFirst()):"` |
| `ObjCDeclarationRendering/ObjCDump+SemanticString.swift:376` | `"set\(name.uppercasedFirst):"` | `"set\(name.box.uppercasedFirst()):"` |
| `ObjCDeclarationRendering/ObjCDump+SemanticString.swift:944` | `afterPreposition.lowercasedFirst` | `afterPreposition.box.lowercasedFirst()` |
| `ObjCDeclarationRendering/ObjCDump+SemanticString.swift:949` | `workingLabel.lowercasedFirst` | `workingLabel.box.lowercasedFirst()` |

### 非目标

- **不改 `orEmpty` / `removingAll(where:)` / `Set.insert(contentsOf:)` /
  `OffsetEnumeratedSequence`** —— 上游没有对应物。把它们提交进 FrameworkToolbox 再回来用，
  是另一件事，见「替代方案考量」。
- **不试图恢复 Linux** —— 那需要先动 `swift-objc-dump`。
- **不动 `MachOObjCSection` target 自身**（`FileHandleHolder` 的 `NSRecursiveLock`、
  `DyldCacheLoaded+.swift` 的裸 `os_unfair_lock`）。那是上游 fork 的代码，改它会平白增加
  与上游合并的冲突面，收益为零。
- **不改任何 public API**。

## 详细设计

### `@Mutex` 展开成什么

```swift
@Mutex
private var classes: [String: ObjCClassGroup] = [:]
```

展开为（宏 `@attached(peer, names: prefixed(_))` + `@attached(accessor)`）：

```swift
private let _classes = Mutex<[String: ObjCClassGroup]>([:])
private var classes: [String: ObjCClassGroup] {
    get { _classes.withLock { $0 } }
    set { _classes.withLock { (value: inout [String: ObjCClassGroup]) -> Void in value = newValue } }
    _modify {
        let valuePointer = _classes._unsafeLock()
        defer { _classes._unsafeUnlock() }
        yield &valuePointer.pointee
    }
}
```

与现有手写形状的差别只有两个：底层锁从 `NSLock` 变成 `os_unfair_lock`，以及多出 `_modify`。

### `_modify` 带来的一个新约束：不可重入

`os_unfair_lock` 不可重入。`_modify` 的 `yield` 期间锁是持着的，所以**在一个 `classes[…]`
的读-改-写过程中再访问 `classes`，会死锁**，而现在的 get/set 形状只会读到旧值。

`prepare()` 里所有访问都是「取一个 key / 写一个 key」的直筒形状，不存在嵌套，实测与 review
都要确认这一点。这条约束写进 `ObjCInterfaceIndexer` 的存储区注释。

### `sending` 约束可能需要 `withLockUnchecked`

上游 `withLock` 的签名是：

```swift
public borrowing func withLock<Result: ~Copyable, E: Error>(
    _ body: (inout sending Value) throws(E) -> sending Result
) throws(E) -> sending Result
```

`ObjCClassGroup` 等值类型是否满足 `sending` 的区域推断，要编出来才知道。若报错，上游提供了
`withLockUnchecked`（无 `sending` 约束）作为退路 —— 但那需要不用宏、手写访问器。
**若走到这一步，本提案的 `@Mutex` 部分就地放弃**，只保留字符串工具的部分，并把结论记进决策日志。
这是本提案唯一一处「可能落不了地」的地方，落地步骤里排在最前面验证。

### `.box.` 在 `Substring` 上也成立

`ObjCDump+SemanticString.swift:944` 的 `afterPreposition` 是 `Substring`。上游的方法定义在
`extension FrameworkToolbox where Base: StringProtocol`，而 `Substring` 通过
`@FrameworkToolboxExtension extension Collection {}` 拿到 `.box`，所以成立。仍需编译验证。

## 替代方案考量

### 维持现状，什么都不动

代价是「四、`uppercasedFirst` 已经被抄了两份」里说的那条：每多一个需要它的 target 就再抄一份。
而且 0001 写在注释里的两条理由已经是错的，留着它们比删掉更有害 —— 下一个人会照着这两条
错误理由继续手搓。**即使不采用上游实现，那几段注释也必须改**。既然要改，不如直接用上游的。

### 把 `orEmpty` / `removingAll(where:)` 提交进 FrameworkToolbox，然后一起用

方向上更彻底，但会把本提案变成一个跨两个仓库、需要先发 FrameworkToolbox 新版本才能推进的
改动，而收益只是再少三十行本地代码。**本轮不做**，留作后续。若将来 FrameworkToolbox 补上了
这几个，本地副本再删也不迟。

### 只删 `Mutex`，字符串工具留着

`Mutex` 那份收益最明确（`_modify` 的原子性 + 少一个自己维护的锁）。但字符串那两份正是
「被抄了两遍」的那一对，是重复代码的实际发生地。两件事的理由是同一条，分开做没有意义。

### 把本地 `Mutex.swift` 换成上游源码的完整副本（vendoring）

即不加依赖，把上游 `Mutex.swift` 逐字抄进 `Internal/`。这样能拿到 `os_unfair_lock` 和
`_modify` 所需的 `_unsafeLock` / `_unsafeUnlock`，却不用加依赖。

**否决**：拿不到 `@Mutex` 宏（宏必须来自 `.macro` target），所以访问器还是要手写；而且从此
要自己跟着上游修 bug。「不加依赖」在这里换不到任何东西 —— 依赖本来就已经在图里了。

### 依赖 `OSToolbox` 而不是 `SwiftStdlibToolbox`

层次上更薄（不拖 `DyldToolbox` 那条 C shim）。**否决**：`OSToolbox` 这个 product 还没发布，
只存在于 FrameworkToolbox 的本地 HEAD。等它发布后可以再收窄，那是纯内部调整。

## 影响

### 源码兼容性（source compatibility）

**public API 零改动。** 删掉的三处都是 `internal`，改动的四个调用点都在实现内部。
调用方一行不用改，也不会看到任何行为差异 —— 索引结果、渲染输出、CLI 输出全都逐字不变。

唯一对外可见的变化是**依赖图里多了一条直接边**：消费本库的项目若自己也依赖
FrameworkToolbox 且版本低于 0.9.0，SPM 会把它抬到 0.9.0。考虑到它本来就已经被
`swift-objc-dump` 拉到 0.9.0，实际影响为零。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发，未开启 library evolution，也无 `binaryTarget`。

### API 演进与废弃策略

无 API 变更，无废弃项。

### 下游影响

- **RuntimeViewer**：无感。它消费的是 `ObjCInterfaceIndexer` / `ObjCInterfaceBuilder` 的
  public 面，签名与行为都不变。它本身也已经在依赖 FrameworkToolbox。
- **MachOSwiftSection / MachOKitUI**：不受影响。
- **Linux 消费者**：不存在（今天就构建不过，见「动机二」）。

**上游 fork 传导**：改动全部落在 0001 新增的三个 target（`ObjCIndexing`、
`ObjCDeclarationRendering`、`ObjCInterface`）与 `Package.swift`，
`Sources/MachOObjCSection/` 一行未动，不增加与上游 `p-x9/MachOObjCSection` 的合并冲突面。

### 文档与示例

必须同批次改的：

1. **`Documentations/Internal/ObjCRenderingAndIndexingImplementation.md`**
   - 「Linux 支持：真正的障碍是什么」一节：结论订正为「`FoundationToolbox` 经
     `ObjCDump` 进来，Linux 已不通；0001 对 `MachOKitExtensions` 的三处改写没有保住 Linux，
     但改写本身无害（标准库调用等价且更直接），故保留」。
   - 「`ObjCIndexing` 的锁」一节：整节重写为「用上游 `@Mutex`」，并记下
     `_modify` 的不可重入约束。
2. **`Documentations/Evolutions/0001-*.md`**：**保持原貌**。它是决策快照，
   「当时为什么判断引入不划算」有记录价值。推翻记在本提案里。
3. **`Documentations/Evolutions/README.md`** 与 **`Documentations/README.md`**：登记本提案。
4. **`README.md`**：无需改 —— 它不列依赖，也没有 Linux 承诺。
5. **`CLAUDE.md`**：本仓库无项目级 CLAUDE.md，不涉及。

## 落地步骤

1. **先验证 `@Mutex` 能编过**（本提案唯一的可行性风险点）。
   在 `Package.swift` 加依赖与三个 product，把 `ObjCInterfaceIndexer` 的一个存储
   （`_structs`，最简单的 `[String: CStructOrUnion]`）改成 `@Mutex`，
   `swift build --scratch-path /tmp/claude/SwiftPM/MachOObjCSection` 通过即继续；
   若 `sending` 报错且 `withLockUnchecked` 也救不回来，退回「只做字符串工具」并记入决策日志。
2. 五个存储全部改成 `@Mutex`，删 `Internal/Mutex.swift`，补存储区的不可重入注释。
3. 四个调用点改成 `.box.` 形式，删 `String+Utilities.swift`，
   删 `Collection+Utilities.swift` 里的 `extension String`。
4. `swift build` 全绿；`swift test --skip MachOObjCSectionTests` 全绿
   （`MachOObjCSectionTests` 有硬编码本机路径的既有问题，与本提案无关）。
   **测试成败只认 `swift test` 的退出码**。
5. **行为不变的证据**：改动前后各跑一次
   `objc-section dump --uses-system-dyld-shared-cache -n Foundation`，
   `diff` 必须为空。这是本提案「输出逐字不变」这条承诺的验收方式 ——
   仅靠单元测试不足以覆盖渲染层全部路径。
6. 按「文档与示例」改文档，状态改 `Implemented`，与代码同一个 commit。

## 落地结果

全部步骤已完成，与提案的偏差有两处，都在下面记清。

### 与提案的差异

| 提案怎么说 | 实际怎样 |
|---|---|
| 唯一的可行性风险是 `withLock` 的 `sending` 约束 | **`sending` 完全没成问题**，`withLock { $0 }` 直接编过。第一次试编确实失败了，但原因完全是另一个：**本地 `Internal/Mutex.swift` 与导入的 `SwiftStdlibToolbox.Mutex` 同名，而同模块内的类型优先于导入的类型**，宏展开里的 `Mutex` 仍解析到本地那个 `final class`，报 `value of type 'Mutex<…>' has no member '_unsafeLock'`。先删本地文件再改用宏即可 |
| 要改的调用点有 4 个 | **6 个** —— 漏了 `Tests/ObjCInterfaceTests/ObjCInterfaceTests.swift` 里的两处（`@testable import ObjCInterface` 让那份 internal `uppercasedFirst` 对测试可见）。`ObjCInterfaceTests` 因此也要加 `FoundationToolbox` 依赖。**教训：删 internal 扩展前要连 `Tests/` 一起 grep**，`@testable` 会把 internal 面暴露出去 |

### 验收记录

- `swift build` 通过；`swift test --skip MachOObjCSectionTests` **退出码 0**，
  64 个测试 6 个套件全绿（`MachOObjCSectionTests` 硬编码本机路径，与本提案无关）。
- **输出逐字节不变**：用 `git worktree` 在 HEAD 上单独构建了一份基线 `objc-section`，
  与改动后的版本对 `Foundation` / `AppKit` / `CoreFoundation` 三个 cache 镜像各跑三组开关
  （无开关、四个 strip、四个 emit）共 9 次 dump，`diff` 全部为空。最大一次是 AppKit 的
  122977 行。其中 `--emit-property-accessor-addresses` 在 Foundation 上产出 374 条
  `setter IMP` 注释，确认渲染层那处 `uppercasedFirst` 的确被走到，不是空跑。
- `swift package update` 报 `Everything is already up-to-date`，`Package.resolved` 零改动 ——
  实测印证了「加这条依赖的边际成本是零」。

## 决策日志

| 日期 | 决策 | 理由 |
|---|---|---|
| 2026-08-13 | 推翻 0001 的「不引入 FrameworkToolbox」 | 它的前提（引入要付新成本、Linux 要保）在 0001 落地时就已经不成立：`swift-objc-dump` 2026-01-03 起就把 `FoundationToolbox` 拉进了依赖图 |
| 2026-08-13 | 依赖 `SwiftStdlibToolbox` 而非 `OSToolbox` | `OSToolbox` 拆分尚未发布，`0.9.0` tag 里 `@Mutex` 仍在 `SwiftStdlibToolbox`；且拆分后它会 `@_exported import OSToolbox`，两个方向都成立 |
| 2026-08-13 | `orEmpty` / `removingAll` / `OffsetEnumeratedSequence` 留在本地 | 上游没有对应物。提交进 FrameworkToolbox 会把本提案变成跨仓库、需先发版的改动，收益只有三十行 |
| 2026-08-13 | 不动 `MachOObjCSection` target 里的两处锁 | 那是上游 fork 的代码，改它平白增加合并冲突面，收益为零 |
| 2026-08-13 | 不试图恢复 Linux，只订正文档 | 前置条件在 `swift-objc-dump`，属另一个仓库 |
| 2026-08-14 | `sending` 的退路（`withLockUnchecked` + 手写访问器）没有用上 | 实测直接编过。提案里预留的「就地放弃 `@Mutex` 部分」这条分支未触发 |
| 2026-08-14 | 0001 的实现说明就地订正，而非另起一篇 | 它是 0001 的配套实现说明，「Linux 的真正障碍是什么」这一节的结论错了就该改对 —— 实现说明是活文档，与提案（决策快照，保持原貌）相反。0001 提案正文未动 |
