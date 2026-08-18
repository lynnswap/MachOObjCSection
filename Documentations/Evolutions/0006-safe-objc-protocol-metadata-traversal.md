# 0006 - 安全读取并有界遍历 Objective-C protocol metadata

- **状态**: In Review
- **作者**: Kazuki Nakashima
- **创建日期**: 2026-08-18
- **最后更新**: 2026-08-19
- **所属愿景**: 无
- **关联提案**: 无（编号 0005 已由较新的 upstream main 占用，本分支以 0.8.104 为基线）
- **实现分支 / PR**: `codex/fix-protocol-metadata-traversal`
- **配套文档**: 无 —— 本文同时是 SPI consumer contract 与实现决策的正本

## 摘要

Mach-O 与 dyld shared cache 都是外部输入。当前 protocol-list reader 在文件范围不足时用
`try!` 终止宿主进程；完整 protocol info 的默认递归也没有环检测，遇到 `A -> B -> A`
会耗尽线程栈。

本提案把两个 invariant 归还各自 owner：

1. protocol-list parser 在分配和读取前验证 count、字节数、地址加法与 backing range；整张表
   不可读则丢弃整张表，单个 pointer 无法解析则只丢该 entry。
2. 每次根 `readInfo` 调用独占一份有序路径与 active identity set。环边和超过 64 条引用边的
   边只物化为 name-only leaf，不再递归。

普通 public `info(...)` 保持签名不变，只丢弃诊断。需要解释降级原因的工具可显式导入
`Diagnostics` SPI，并取得值与确定顺序的 typed diagnostics。

## Consumer story 与 interface-first sketch

第一 consumer 是生成 private header 的命令行工具。它既要保留能生成的 class/protocol/category，
也要把被跳过的 protocol metadata 归因到当前 subject，而不能让一个坏 entry 终止整个 target。

```swift
@_spi(Diagnostics) import MachOObjCSection

let result = objcClass.readInfo(in: machO, options: .headerDump)
if let classInfo = result.value {
    render(classInfo)
}
for diagnostic in result.diagnostics {
    report(diagnostic)
}
```

新增 surface：

```swift
@_spi(Diagnostics)
public struct ObjCMetadataReadResult<Value> {
    public let value: Value?
    public let diagnostics: [ObjCProtocolDiagnostic]
}

@_spi(Diagnostics)
public enum ObjCProtocolDiagnostic: Sendable, Equatable {
    case unreadableList(UnreadableList)
    case cycle(Cycle)
    case recursionLimit(RecursionLimit)
    case invalidIdentity(InvalidIdentity)
}

// ObjCClassProtocol / ObjCProtocolProtocol / ObjCCategoryProtocol each expose:
@_spi(Diagnostics)
public func readInfo(
    in machO: MachOFile, // and MachOImage overload
    options: /* existing option type */
) -> ObjCMetadataReadResult</* existing ObjCDump info type */>
```

SPI 不承诺 ABI。普通 source consumer 不导入 SPI，现有 `info(...)` 仍能原样编译。

## Owner map

| invariant | 当前 owner 缺口 | 新 owner |
|---|---|---|
| pointer table 的 count/range 可读 | 通用 `_FileIOProtocol.readDataSequence` 内 `try!` | protocol-list 专用 checked reader |
| 单 entry 失败不拖垮同表其它 entry | `compactMap` 没有失败证据，layout read 仍可 trap | protocol-list reader 的 ordered outcome |
| traversal 不沿环递归 | `.recursive` 把同一 options 无限传下去 | 每个根 `readInfo` 的 path-scoped context |
| 降级可解释 | `nil`/`[]` 混淆 absent 与 malformed | `ObjCMetadataReadResult` 的 typed diagnostics |
| 日志策略 | library 若直接写 stderr 会越权 | consumer 读取 SPI 后自行记录 |

## Parser 设计

只替换 Objective-C protocol list 的读路径，不顺手改 method/property/ivar 的通用 helper。

### 整表验证

按以下顺序验证，任何一步失败都不分配 pointer array、不做读取，并返回 unreadable-list diagnostic：

1. raw `UInt32` / `UInt64` count 必须能 exact 转成 `Int`；
2. `count * advertisedStride` 使用 checked multiplication；
3. list offset、header size、table bytes 的加法不得 overflow；
4. file mode 必须完全落在 backing file range；image mode 必须是当前 task 可读 range。

所有 file/image、regular/relative protocol table 共用两项资源预算：最多 **65,536 entries**，且
完整 strided table 最多 **512 KiB**。regular 64-bit table 在两项上限处恰好是 512 KiB；relative
table 即使只有一个 entry，也不能用接近 4 GiB 的 advertised stride 绕过预算。两个 cap 都在 file
read、image probe、allocation 与 `reserveCapacity` 之前执行，并分别以 typed excessive-count /
excessive-byte-count diagnostic 报告。按 4 KiB page 计算，单表最多触及 129 页。

### 单 entry 验证

整表有效后保持声明顺序逐项处理。无法 rebase、找不到 backing data、或 protocol layout range
不可读时，仅跳过该 index，并附上 typed entry failure。其它 entry 继续返回。`MachOImage`
在任何 `.pointee` 前 probe 完整 layout range；通常 reference 仍先确定 target image。

dyld shared cache 的 [canonical protocol](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/cache_builder/NewSharedCacheBuilder.cpp#L7735-L7845)
位于 cache-wide `__OBJC_RW`，不属于任何 Mach-O image。
loaded reader 只有在 Objective-C runtime 的 registered protocol snapshot 中 exact match 时，才把这种
pointer 恢复为 name-only reference；输出名仍读取 canonical layout 的 raw mangled name。这个恢复只服务
header dump 的 direct-name policy。full metadata request、unknown pointer 与 unreadable layout 继续产生
原有 bounded diagnostic，不能把 caller image 伪装成 canonical object 的 owner。

loaded-image range probe 仍沿用项目已有的 `mach_vm_read_overwrite` C bridge，但把原来的
first/last-page 检查补全为每个 touched page。same-page struct 仍只做一次 probe；跨页 protocol
table 不会漏掉中间 unmapped page，也不需要为每个 pointer slot 单独发一次 Mach syscall。

### Relative list-of-lists

Objective-C runtime 的 `relative_list_list_t` 不是按 class owner image index 查询单个 list 的
lookup table。outer table 的每个 entry 各自保存所属 image index 和到 inner list 的 signed 48-bit
offset。file/debug-tool reader 按 table 顺序读取全部 entry；loaded-image reader 则先以该 entry 的
image index 查询 runtime RW header-info loaded bit，unloaded entry 在计算 list address 前静默跳过。

protocol reader 因此返回有序的 0...n 个 resolution。一个 loaded entry 的 location、header 或 target
image 无法解析时，只在原位置产生 typed failure，后续正常 list 继续解析；同一 image index 的重复
entry 也不得合并。合法 table 没有 loaded entry 是成功的空结果，owner entry 不存在本身不是错误。
整表 count、stride、byte budget 或 backing range 无效时仍返回单个 whole-table failure，并且不会调用
load-state、location 或 image resolver。

method/property 也使用相同 ABI representation，但现有 public/internal 读取面没有 protocol path 的
ordered typed outcome。本 follow-up 只修复已有安全诊断契约覆盖的 protocol reader；method/property
需要在建立同等 failure contract 后单独迁移，不能接到会用 `compactMap` 丢失错误的旧 plural helper。

## Traversal 设计

### identity

- dyld-cache file mode：main cache UUID 与 canonical unslid protocol address 的组合；subcache wrapper
  被重新打开也不改变 identity。
- non-cache file mode：standardized source path、Mach-O header offset 与 protocol offset 的组合。
- image mode：protocol object 的实际 address。

名称不参与 identity；不同 image 可合法出现同名 protocol。

### path-scoped DFS

每个根 `readInfo` 创建新的 context，持有：

- root subject（class / protocol / category）；
- 有序 protocol name path；
- active identity set；
- 当前 reference-edge depth；
- 按发现顺序追加的 diagnostics。

进入 full child 前 insert，返回时 remove。这样 `A -> C` 与 `B -> C` 的 diamond DAG 会在两条路径
各自保留 C，而 `A -> B -> A` 会在第二个 A 处截断。不同根调用绝不共享 state。

判定顺序是 cycle 先于 hard limit。命中任一者时保留该边的 protocol name，生成 shallow leaf，
不读取其 members/references。

### 为什么是 64

iOS 27.0（24A5390f）shared-cache 扫描观测到 48,743 个 protocol nodes，最长路径 7 条边，
另有 2,096 个 shared descendants。64 是实测最大值的九倍以上，能容纳正常 metadata 的增长，
同时在 hostile acyclic chain 上给 CPU、stack 与输出体积一个固定上界。

hard limit 对所有 traversal 生效，包括 `.recursive` 和 `.depth(n)` 中 `n > 64`。调用方主动设置
`.depth(n)` 且在 `n <= 64` 处耗尽属于正常策略，不产生 warning；只有 cycle 或 hard cap 产生诊断。

## Diagnostics contract

diagnostics 与 metadata walk 同序，且每次根调用从空数组开始。payload 不以一组互相制约的 optional
字段表达状态，而用关联值区分：

- whole-table invalid/excessive count、invalid/excessive stride bytes、multiplication/range overflow、
  unreadable file/image range；
- regular/relative list header unreadable、relative image/index/location resolution failure；
- skipped entry 的 unresolved rebase / invalid offset or pointer / invalid identity / missing backing data /
  unreadable layout；
- root protocol 的 canonical traversal identity 无法建立；
- cycle path；
- recursion-limit path 与固定 limit。

每条都带 root subject；list failure 另带当前 protocol path 与 list offset。library 不打印、不注入
logger，也不把 handler 塞进 `Sendable` options。

## Source / ABI compatibility

- **source**：兼容。现有 public `info(...)` 签名和默认 options 不变，内部委托 `readInfo(...).value`。
- **behavior**：malformed metadata 从进程终止降级为 partial info；合法的递归树输出不变。环边与第 65
  条边以后改为 name-only leaf。
- **ABI**：不承诺。本库以 SwiftPM source 分发、未启用 library evolution；新增 surface 又明确是 SPI。
- **不采用**：不把现有方法改成 `throws`，不改变 `.recursive` 默认值，不增加全局 visited set，
  不从 library 写 stderr。

## 测试计划

仓库内回归使用合成 bytes / graph，不依赖 host system framework，覆盖：

1. 32/64 count exact conversion、signed 48-bit relative displacement、byte multiplication/address
   addition overflow、OOB table；
2. 一条坏 entry 与一条好 entry 同表时保留好 entry，并记录坏 index；
3. class/protocol/category root subject；
4. self-cycle、`A -> B -> A`、diamond DAG、cross-root reset；
5. 第 65 条边 shallow + 单条 limit diagnostic；
6. `.depth(1)` 保留 direct names 且无 limit diagnostic；
7. 旧 `info` wrapper 不 trap；
8. file/image 与 regular/relative 四条路径的 entry/byte resource budget；
9. MachOFile / MachOImage 两条路径；
10. image 外 registered protocol 的 direct name、unknown pointer、unreadable registered pointer，及
    full metadata 不使用 name-only recovery。

## 决策日志

| 日期 | 变更 | 说明 |
|---|---|---|
| 2026-08-18 | Created / Accepted / In Progress | iOS 27 MatterSupport、MetricKit 的 OOB trap 与 SensorKit 的 cyclic recursion 共同暴露 parser/traversal owner 缺口 |
| 2026-08-18 | hard ceiling 取 64 | scan 为 48,743 nodes / max 7 edges / 2,096 shared descendants；64 保留充足余量并限制 hostile chain |
| 2026-08-18 | 选择 path-scoped set，不选 global visited | global set 会把 diamond DAG 的第二条合法路径误判成重复并静默删掉 |
| 2026-08-18 | diagnostics 采用值结果 SPI | options handler 会改变 Sendable configuration 的职责；library stderr 会夺走 consumer 的日志策略 |
| 2026-08-18 | image range probe 改为检查每个 touched page | first/last 不能证明中间页可读；逐 entry probe 又会在 48,743-node scan 上放大 syscall 数 |
| 2026-08-18 | 全 protocol table resource budget 取 65,536 entries / 512 KiB | 同时约束 count 与 advertised stride；mapped/file-range 大小不再决定 parser 愿意承担的工作量 |
| 2026-08-18 | In Review | fork branch 已实现并进入 review；只有合并后才能按本仓库定义改为 Implemented。最终 test/build 实绩在 review 修正收敛后更新 |
| 2026-08-18 | Review corrections complete | synthetic safety tests 31 件全绿；排除基线既有 hardcoded `/Users/JH/Downloads/iOS18.5-SwiftUI` XCTestCase 后合计 66 tests 全绿；release、iOS Simulator arm64/x86_64、watchOS（含 arm64_32 compile）build 成功；状态仍保持 In Review，等待下游验证与合并 |
| 2026-08-18 | Canonical protocol follow-up | watchOS 27 的 cache-wide canonical protocol pointer 没有 dylib owner。direct-name policy 通过 exact runtime registry identity 恢复 raw mangled name；full reads 和 unknown pointers 继续产生 bounded diagnostic。 |
| 2026-08-19 | Relative list-of-lists follow-up | 按 objc4 iterator contract 改为 file 全 entry、loaded image 仅 loaded entry 的有序 plural resolution；owner index 不再是 protocol reader 输入，单 entry failure 不丢后续 sibling。 |
