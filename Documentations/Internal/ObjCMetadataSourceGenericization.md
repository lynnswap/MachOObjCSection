# 泛型化到 MachOFile 的实现说明

- **对应提案**: [0002](../Evolutions/0002-objc-machofile-genericization-and-cli.md)
- **最后更新**: 2026-08-12

这份文档记录 0002 落地过程中那些**从代码本身看不出来**的决策，以及与提案设想不一致的地方。
提案是决策快照，保持原貌；偏差记在这里。

面向使用者的契约与已知限制在[使用指南](../Guides/ObjCSectionCommandLine.md)，不在这里重复。

## 分层

```
MachOObjCSection          纯解析，未改动
        ↑
ObjCMetadataSource        ← 本次新增。把双重载收敛成以 Self 为参数的泛型 requirement
        ↑
ObjCDeclarationRendering  ObjCRenderingContext<MachO> 在这一层
        ↑
ObjCIndexing              ObjCInterfaceIndexer<MachO>
        ↑
ObjCInterface             ObjCInterfaceBuilder<MachO>
        ↑
objc-section              命令行
```

新 target 夹在核心解析层与渲染层之间。它可以依赖 `MachOKitExtensions`（渲染层本来就依赖），
因此地址换算不必重写 —— 而核心 `MachOObjCSection` target 依然不能依赖它，那会造成包级循环
（MachOSwiftSection 依赖 MachOObjCSection 的高层 product）。

## 为什么 shim 协议不放进核心 target

技术上更自然的位置是 `MachOObjCSection` 自己 —— 抽象应该和被抽象的东西住在一起。
放在新 target 是为了**边界清晰**：核心目录是上游文件的领地，本 fork 往里加文件会让
「这个目录里哪些是我们加的」变得模糊，且上游日后若自己加了同名抽象就会撞车。
独立 target 随时可以在上游接受同等抽象后原样删掉，删除动作是一次 `Package.swift` 改动。

代价是 `ObjCClassProtocol.name(in: MachOFile)` 这个补齐扩展也住在新 target 里，
而它的兄弟方法 `name(in: MachOImage)` 在核心 target。查找时会觉得割裂 —— 这是有意付的成本。

## `ResolvedSource` 这个 associatedtype 是被逼出来的

提案里的签名是这样的：

```swift
func objcSuperClass<Class: ObjCClassProtocol>(of objcClass: Class) -> (Self, Class)?
```

**这个签名编译不过**：

```
error: protocol 'ObjCMetadataSource' requirement 'objcSuperClass(of:)' cannot be satisfied
by a non-final class ('MachOFile') because it uses 'Self' in a non-parameter,
non-result type position
```

`MachOFile` 是一个**非 final 的 class**。Swift 只允许非 final class 满足那些把 `Self` 用在
参数或返回值**顶层**的 requirement —— 因为子类无法保证元组里那个 `Self` 的协变正确性。
元组内部就算「非顶层」。

所以协议改成声明一个 associatedtype，两个 conformance 都把它写成自己：

```swift
associatedtype ResolvedSource: ObjCMetadataSource where ResolvedSource.ResolvedSource == ResolvedSource

func objcSuperClass<Class: ObjCClassProtocol>(of objcClass: Class) -> (ResolvedSource, Class)?
```

`where` 子句是必需的，不是装饰。超类链是循环走的：

```swift
var machOAndSuperclass: (MachO.ResolvedSource, Class)? = machO.objcSuperClass(of: cls)
while let (currentMachO, currentSuperclass) = machOAndSuperclass {
    machOAndSuperclass = currentMachO.objcSuperClass(of: currentSuperclass)
    …
}
```

第二行赋值的右侧类型是 `MachO.ResolvedSource.ResolvedSource`。没有那条 `where`，
每走一跳类型就多嵌套一层，循环根本写不出来。有了它，一跳之后类型就固定了。

### 考虑过但没采用的替代

把「走完整条超类链」本身做成 requirement（返回 `[ObjCClassInfo]`，不含 `Self`），让两个
conformance 各写一遍循环。这样协议签名干净，但 shim 层就从纯转发变成了承担业务逻辑，
且那段循环要复制两份。`ResolvedSource` 是一次性的、局部的复杂度，选它。

## IMP 地址：提案把语义写窄了

提案说「`impAddressComment` 改走 `objcResolvedAddress(forOffset:)`」，即只抽象「偏移 → 地址」
这半段。**实际不成立** —— `imp` 这个原始值在两种模式下含义就不同：

| 模式 | `ObjCMethodInfo.imp` 里存的是什么 |
|---|---|
| 镜像模式 | 活的函数指针，带 slide 的绝对运行时地址 |
| 文件模式（独立文件） | 文件偏移。`ObjCMethodList.pointerMethod(_:in:)` 解码时就换算好了 |
| 文件模式（cache 内） | `地址 - sharedRegionStart`，同样是偏移 |
| 文件模式（relative method list） | `entryOffset + relative + 8`，直接就是偏移 |

镜像模式要先减去镜像基址才能得到偏移，文件模式不能减。所以抽象的边界必须往前挪一格，
覆盖整段「原始值 → 可显示地址」：

```swift
func objcResolvedIMPAddress(forRawValue rawValue: UInt64) -> UInt64?
```

两个 conformance 各自归一化后再交给共享的 `address(forOffset:)`。返回 `nil` 表示这个字段
不是有效的实现指针（值为 0，或镜像模式下低于镜像基址）。

`Tests/ObjCMetadataSourceTests` 里有一条测试专门比对两种模式解析出的 IMP 地址是否相等 ——
如果哪一侧的归一化写错，别处的输出仍然会一致，只有这条会失败。

手工验证：对 `AssetCatalogFoundation` 导出的 `// IMP: 0x10AE88` 与 `0x10AF14`，
用 `otool -tV` 查这两个地址，都精确落在函数序言（`stp x26, x25, [sp, #-0x50]!`）上。

## 源码兼容性有一个提案没提到的例外

提案说「泛型参数可由构造器实参推断，调用点无需改写」。这是对的，但只覆盖了调用点。
**显式写出类型名的地方必须补泛型参数**：变量类型标注、函数返回类型、存储属性类型。

本仓库自己的测试就撞上了三处（`Tests/ObjCIndexingTests`、`Tests/ObjCInterfaceTests`），
都是 `-> ObjCInterfaceIndexer` 这样的返回类型标注。下游若把 indexer 存成属性，同样要改。

写法见[使用指南](../Guides/ObjCSectionCommandLine.md#库调用方泛型参数是推断出来的)。

## 渲染层选择了泛型而不是 existential

`ObjCRenderingContext` 用 `machO` 只做一件事：解析 IMP 地址。所以有两条更轻的路：
把 `machO` 存成 `any ObjCMetadataSource`，或者干脆换成一个地址格式化闭包。两者都不会让
`ObjCDump+SemanticString.swift` 里十来个 `semanticString(using:)` 变成泛型方法。

仍然选了泛型，理由是**源码兼容性**：`context.machO` 在 existential 方案下类型会从 `MachOImage`
变成 `any ObjCMetadataSource`，下游任何读这个属性的代码都会断；泛型方案下它仍然是
推断出来的具体类型。传染面（约 15 处方法签名加一个泛型参数）是一次性的机械改动，
而且这些文件都是本 fork 自己的，不涉及上游合并冲突。

## 与提案不一致的地方

### 测试形态：快照测试换成了选项解析 + 双模式一致性

提案第 7 步要求「用 `swift-snapshot-testing` 对若干固定的系统二进制跑 `dump`，固化输出」，
并说这是对标 MachOSwiftSection 的 `SwiftSectionCommandTests`。

查证后发现**对标对象里并没有这种测试** —— `SwiftSectionCommandTests` 实际只有一份
`TransformerOptionGroupTests.swift`，测的是选项组解析。而对系统二进制固化快照本身有问题：
输出会随 macOS 版本漂移，测试会周期性地因为系统升级而变红，且在别的机器上无法复现。

实际落地为两个 target：

| Target | 测什么 |
|---|---|
| `ObjCSectionCommandTests` | CLI 选项解析：十个开关各自映射到对应的 `ObjCGenerationOptions` 字段、C 类型替换的两种拼写与错误处理、ivar 模板、子命令树 |
| `ObjCMetadataSourceTests` | 双模式一致性：同一个二进制分别以 `MachOFile` 与 `MachOImage` 索引，类 / 协议 / 分类 / struct / union 名字集合相同，逐个类的渲染输出逐字符相同，IMP 地址解析结果相同 |

双模式一致性测试用的是**测试 bundle 自己的二进制** —— 它是测试进程能拿到的唯一一个
既已加载（`MachOImage` 看得见）、又在磁盘上有独立文件（`MachOFile` 打得开）的目标。
系统框架不行：它们的 install path 只存在于 cache 里，没有文件可开。

这个测试同时把两条**允许存在的差异**钉死为已知项，而不是让它们某天变成惊喜：
文件模式的超类链更短（因而 `stripOverrides` 剥得更少），以及纯 Swift 类的 ivar 记录对不上。

### 没有实现的两个进度反馈细节

提案示例里写的是 `indexer.prepare(eventHandler:)`。实际 API 是在 `init` 传 handler，
`prepare()` 无参 —— 事件在遍历过程中投递、之后不保留，没有事后附加 handler 再补事件的可能。
CLI 的 `-v` 因此在构造 indexer 时就绑好 handler。

## 落地时发现的两个上游缺陷

两个都**不是 0002 引入的**，调用链完全在上游 API 内部，本层只是转发。第一个已随依赖升级解决，
第二个仍在。记在这里以免下次重新发现一遍。使用者视角的说明在
[使用指南](../Guides/ObjCSectionCommandLine.md#必须知道的四件事)。

### macOS 26 的 cache 拿不到 objc image index（已随 MachOKit 0.52.101 解决）

**结论先行**：本项目依赖已提到 `0.52.101`，问题不复存在，本项目一行代码都没改。下面是排查过程，
留着是因为症状太隐蔽 —— 不报错，只是输出里悄悄少掉方法和属性 —— 一旦依赖被降级会重新出现。

`MachOFile.objcImageIndex`（`Sources/MachOObjCSection/Extension/MachOFile+.swift`）在
macOS 26.5.2 的 cache 上返回 nil，后果是所有 relative list list 按 index 的查找落空 ——
方法、属性、协议列表全空，只剩 ivar。macOS 15.5 的 cache 一切正常，可以用来交叉验证。

**排查时走过一段弯路，记在这里以免重来一遍。** 第一反应是去看 MachOKit 的
`DyldCache.objcOptimization`，它确实返回 nil：`objcOptsOffset` 指向的地址落在子 cache 里，
而它用 `fileOffset(of:)` 解析，只查主 cache 文件。**但这不是失败点** ——
MachOObjCSection 有自己的 `DyldCache._objcOptimization`（`Extension/DyldCache+.swift`），
它走 `locateValue`，会依次在本 cache、主 cache、每个子 cache 里找，能拿到值。
判断上游行为时不要拿 MachOKit 的直接访问器当代理，本库在它上面套了一层。

真正的失败点在下一步，`ObjCHeaderOptimizationROProtocol.headerInfo(in:for:)`：

```
_objcOptimization:              true
_headerOptimizationRO64:        true
headerInfos count:              3163
headerInfo(for: Foundation):    nil        ← 断在这里
locatedCache.url:               dyld_shared_cache_arm64e.03.dyldreadonly
machOFile.cache.url:            dyld_shared_cache_arm64e.01
```

这份 cache 有 12 个子 cache。objc optimization 结构在 `.03.dyldreadonly`，Foundation 在 `.01`。
`headerInfo(in:for:)` 逐条比对 `machO.headerStartOffsetInCache == $0.resolvedMachOHeaderOffset(in: cache)`，
而那个 `cache` 是**找到 optimization 结构的那个**，不是镜像所属的那个 —— 偏移换算基准不同，
3163 条一条都匹配不上。

上游 [p-x9/MachOKit#310](https://github.com/p-x9/MachOKit/pull/310)（2026-08-05，
commit `4335f07` + `484a825`）正是修这一行，改用 `machO.cache` 解析偏移。

**这不是某个版本的回归，而是被 cache 布局触发的。** `headerInfo(in: DyldCache, for: MachOFile)`
在 MachOKit **0.23.0**（`622b458`，2024-10-27）引入，当时比对写作 `$0.offset + $0.machOHeaderOffset`；
**0.24.0**（`e8f0f06`，2024-11-07）改成 `resolvedMachOHeaderOffset(in: cache)`，即今天这个形态，
此后到 0.52.100 一直没变。两种写法都没有「镜像可能在另一个子 cache」的概念，所以 0.23.0 及之后的
所有版本遇到 macOS 26 这种布局都会失败 —— 只是在此之前的 cache 上碰不到。macOS 15.5 的 cache 实测正常。

**镜像模式那条路径不受影响**，`headerInfo(in: DyldCacheLoaded, for: MachOImage)` 比的是指针，
而 `DyldCacheLoaded` 是已映射的连续地址空间，没有子 cache 分文件的问题。#310 也没有动它。

**发布路径**：不能直接切到上游 —— `ObjCHeaderOptimizationRO64/32.headerInfo(at:in:)` 是 MxIris
fork 自己加的 API，上游没有，而 `Sources/MachOObjCSection/Extension/DyldCacheLoaded+.swift:150`
用了它。所以走的是 fork merge upstream/main 再发 tag，即 **MachOKit 0.52.101**（`fec9503`）。
本项目只需把 `Package.swift` 的 `from:` 提上去。

升级后实测：`objc-section interface NSFileManager --uses-system-dyld-shared-cache -n Foundation`
从 5 行变成 132 行完整接口。

**下次验证「某个上游修复是否解决问题」时可以照抄的做法**（全程不改动任何仓库）：把上游 clone 到
scratchpad，加本地 fork 为 remote 并 fetch，在 fork 的 HEAD 上 cherry-pick 待验证的提交，
再临时把 `Package.swift` 的依赖换成指向该目录的 path 依赖，验完还原。一个坑：clone 的目录名必须
与包 identity 一致（这里是 `MachOKit`）—— SPM 的 identity 取自目录名，叫 `MachOKit-upstream`
会和传递依赖里的 `machokit` **冲突报错**，而不是覆盖它。另外临时用过 path 依赖后
`Package.resolved` 会掉 pin，记得 `git checkout Package.resolved` 再重新 build 生成。

### 纯 Swift 类的 ivar 记录两种模式对不上

`ObjCIvarProtocol.offset(in: MachOFile)` 走 `resolveRebase` 读 offset 变量，
`offset(in: MachOImage)` 直接解引用。对编译器为纯 Swift 类生成的 ObjC 兼容记录，
两者读出的值不同（镜像模式为 0，文件模式为别的值），且镜像模式会因为读不到偏移
而丢掉个别 ivar，导致两边 ivar 条数都可能不同。

双模式一致性测试因此跳过名字以 `_Tt` 开头的类，并在注释里写明原因 ——
是排除而不是断言，这样上游修好之后测试不会反过来失败。
