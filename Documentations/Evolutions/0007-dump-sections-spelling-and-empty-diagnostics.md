# 0007 - 修正 dump 的 `--sections` 写法，并让空结果不再无声

- **状态**: Implemented
- **创建日期**: 2026-09-06
- **最后更新**: 2026-09-06
- **所属愿景**: 无
- **配套文档**: [objc-section 使用指南](../Guides/ObjCSectionCommandLine.md)

## 摘要

`objc-section dump` 有两处对外行为缺陷，都由 CLI 的初始提交 `cc87df9` 带入，与
`swift-section` 同源（`MachOOptionGroup` 的形状是从那边照搬过来的，缺陷一并抄了）。
两处都不是本轮改动引入的回归，`git log --all` 里也没有任何既往修复记录。

**一、`--sections` 的两种自然写法全是错的。** 该选项声明为 `parsing: .upToNextOption`，
而输入路径是 `MachOOptionGroup` 里的位置参数 `filePath`，两者并存导致：

| 写法 | 实测结果 |
|---|---|
| `dump --sections classes protocols /bin/ls` | 退出码 64，`/bin/ls` 被当成第三个 section 值 |
| `dump --sections classes,protocols /bin/ls` | 退出码 64，`'classes,protocols'` 不是合法值 |
| `dump /bin/ls --sections classes protocols` | 唯一能用的写法 |

同一个 CLI 里 `evolution --labels 17.0,18.0,26.0` 用的就是逗号分隔单值，也就是它内部
两种多值风格并不一致。

**二、「没内容」和「读不到」完全分不开。** 三种语义完全不同的情况，输出逐字节相同 ——
stdout 0 字节、stderr 0 字节、退出码 0：

| 情况 | 复现命令 |
|---|---|
| 二进制里根本没有 ObjC 元数据 | `dump -a arm64e /bin/ls` |
| 显式点名的类别在该二进制里为空 | `dump -a arm64e --sections structs -- /bin/ls` |
| `--filter` 一个都没匹配上 | `dump --uses-system-dyld-shared-cache -n CoreLocation --filter ZZZNoSuchThing` |

对照组（`dump --uses-system-dyld-shared-cache -n CoreLocation`）输出 267843 字节，
说明加载与索引这条链路本身是通的。同一个 CLI 里 `interface` 子命令这块是对的 ——
找不到就抛 `declarationNotFound` 并以退出码 1 结束，所以不一致的是 `dump` 自己。

本提案把 `--sections` 改成逗号分隔单值，并给三种空结果各补一行 stderr 提示；
退出码在所有空结果情况下保持 0 不变。

## 方案

### 一、`--sections` 改为逗号分隔单值

`DumpCommand.sections` 去掉 `parsing: .upToNextOption`，改为接受一个逗号分隔的单值。
拆分与校验放在一个 `ExpressibleByArgument` 包装类型里，非法成员沿用 ArgumentParser 的
标准报错（列出全部合法取值）。

```
objc-section dump --sections classes,protocols /bin/ls   ✓
objc-section dump /bin/ls --sections classes,protocols   ✓
objc-section dump --sections classes protocols           ✗ 报错并指明改用逗号
```

空格分隔写法在**两个 token**的情况下可以精确识别并给出好报错：此时
`machOOptions.filePath` 会拿到 `"protocols"` 这样一个本身就是合法 section 名的值，
`DumpCommand.validate()` 据此抛出 `ValidationError`，直接告诉用户改成
`--sections classes,protocols`。

**已知局限**：`--sections classes protocols /bin/ls` 这种**三个 token**的情况，
ArgumentParser 会先于 `validate()` 报 `Unexpected argument '/bin/ls'` 并以退出码 64
结束。这条消息不如上面那条精准，但仍是明确报错而非静默误行为，本提案不为它引入
`.allUnrecognized` 之类的兜底位置参数 —— 那会把真正的拼写错误也一并吞掉，代价大于收益。

### 二、空结果各补一行 stderr 提示

`DumpCommand.run()` 在导出循环结束后判断三种情况，各写一行 stderr，**退出码保持 0**，
不影响任何现有脚本：

| 情况 | 提示 |
|---|---|
| 索引里所有类别都为空 | `no Objective-C metadata found in <image>` |
| 显式 `--sections` 点名的某个类别为空 | `no <kind> found in <image>`（逐个类别一行） |
| `--filter` 给了但一个都没匹配上 | `--filter '<text>' matched none of the <N> declarations` |

判据取自 `ObjCInterfaceSession.names(of:)`，不额外走一遍索引。第一种与第二种互斥：
整个索引为空时只报第一条，不再为每个类别重复刷屏。

### 三、顺带合并四份重复的 stderr 写入

`FileHandle.standardError.write(Data((message + "\n").utf8))` 这一行目前在
`DiffCommand`、`EvolutionCommand`、`SnapshotCommand`、`ObjCInterfaceSession` 里各有一份。
本提案要写第五份，因此先抽成 `Utilities/StandardErrorLog.swift` 里的一个函数，四处调用点
改为调用它。纯搬运，不改任何一处的输出内容。

### 测试

三个复现测试进 `Tests/ObjCSectionCommandTests/`，先确认在修复前失败，修复后通过，
作为回归测试永久保留：

1. `DumpCommand.parse(["--sections", "classes,protocols", "/tmp/Sample"])` 解析出
   `[.classes, .protocols]` 且 `filePath == "/tmp/Sample"`。
2. `DumpCommand.parse(["--sections", "classes", "protocols"])` 抛错（空格分隔的两 token 形态）。
3. 三种空结果各自产出预期的 stderr 行、且退出码为 0。空结果这条需要对 stderr 可观测，
   为此把提示行的构造抽成纯函数（输入：各类别名字数量、是否显式点名、filter 命中数），
   测试直接断言该函数的返回值，不去捕获进程的 stderr。

**一处现有测试要改**：`ObjCSectionCommandTests.parsesSections` 目前断言
`["/tmp/Sample", "-s", "classes", "protocols"] → [.classes, .protocols]`，
钉住的正是这次要改掉的意外形状。它会被改写成逗号形态。钉住过不等于支持过 ——
那条断言从未验证过「路径写在选项后面」这个真实用法。

### 文档

- `Documentations/Guides/ObjCSectionCommandLine.md` 第 100 行
  （`| -s, --sections <kinds> | 只导出某几类：... |`）补上逗号写法示例；
  「必须知道的四件事」一节增加一条：dump 的空结果只写 stderr，不改退出码。
- 本提案落地时按 landing-time 规则分配编号，并同步 `Documentations/Evolutions/README.md`
  与 `Documentations/README.md` 的提案表。

### 不做的事

- 不动 `MachOOptionGroup` 的任何拼写。它与 `swift-section` 逐字对齐是有意为之
  （见该文件的注释），两个工具在同一批二进制上换着用，`-n` / `-p` / `-a` 含义一致
  比任何一边单独改进都值钱。
- 不动 `swift-section`（另一个仓库）。那边的同源缺陷由对方会话自行处置，
  本提案只记录同源关系。

## 落地记录

按方案实现。唯一的实现细节偏离：`diagnosticNotes` 的入参从六个平铺参数收成一个
`DumpCommand.Outcome` 结构体，以满足项目 SwiftLint 的 `function_parameter_count`
规则（上限 5 个）；纯函数的性质与语义不变。改动落在 `Sources/objc-section/`：新增
`Models/ObjCSectionKindList.swift`（逗号分隔的 `ExpressibleByArgument` 包装类型）与
`Utilities/StandardErrorLog.swift`（合并后的 stderr 写入），`Commands/DumpCommand.swift`
换上新选项类型并新增 `validate()` 与纯函数 `diagnosticNotes(...)`，
`Utilities/ObjCInterfaceSession.swift` 增加 `isEmpty`，`Models/MachOOptionGroup.swift`
增加 `imageDescription`。

复现与验证保留了修复前的 release 二进制做同机 A/B（`--version` 同为 0.8.105）：

| 场景 | 修复前 | 修复后 |
|---|---|---|
| `--sections classes,protocols -a arm64e /bin/ls` | 退出 64，值不合法 | 退出 0，正常执行 |
| `--sections classes protocols`（空格两 token） | 退出 1，误报「filePath is required」 | 退出 64，指明改用 `--sections classes,protocols` |
| `-a arm64e /bin/ls`（无 ObjC 内容） | stderr 0 字节 | `no Objective-C metadata found in /bin/ls` |
| `-n CoreLocation --sections unions`（索引非空、该类为空） | stderr 0 字节 | `no unions found in CoreLocation` |
| `-n CoreLocation --filter ZZZNoSuchThing` | stderr 0 字节 | `--filter 'ZZZNoSuchThing' matched none of the 188 declarations in CoreLocation` |
| 正常有输出时 | 安静 | 安静（stderr 0 字节，stdout 仍是纯产物） |

三种空结果的退出码在修复前后都是 0，未变。

`ObjCSectionCommandTests` 共 44 个用例通过（原始退出码 0，未经 xcsift 转述）。
新增用例：`ObjCDumpDiagnosticsTests`（11 个，逐条钉住诊断措辞与互斥规则）、
`ObjCSectionCommandTests` 里 6 个 `--sections` 解析用例。

**红-绿的证明方式**：上表的「修复前」一列跑在保留下来的修复前二进制上，是真实失败记录。
新增的单元测试无法在修复前的源码上编译（`--sections` 的类型本身就是这次要改的东西），
因此红是在 CLI 层面证明的，不是靠单元测试在旧源码上跑出来的。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-06 | Created as Draft | 起因是 MachOSwiftSection 会话转来的四条 swift-section 实测教训，逐条比对现有 objc-section 后，确认其中两条中招、两条已做对 |
| 2026-09-06 | 「进度走 stderr」与「fat binary 必须显式 `-a`」不列入范围 | 实测已正确：进度是 `-v` 才开且写 stderr；fat 不给 `-a` 直接报错并列出可用架构，退出码 1 |
| 2026-09-06 | `--sections` 采用逗号分隔单值，而非可重复选项 | 与同一 CLI 里 `evolution --labels` 的既有风格一致；可重复写法（`--sections a --sections b`）虽是 ArgumentParser 惯用法，但会在同一个工具内制造第二种多值风格 |
| 2026-09-06 | 空结果只写 stderr，退出码保持 0 | 不让任何现有脚本或 CI 因为一次诊断性改进突然变红；需要门禁的场景已有 `diff --fail-on-breaking` 这条专用通道 |
| 2026-09-06 | 三 token 形态的报错质量降级为已知局限，不引入兜底位置参数 | `.allUnrecognized` 会连真正的拼写错误一起吞掉，换来的只是一条更好看的消息；退出码 64 的明确报错已经不是静默误行为 |
| 2026-09-06 | 走轻量档而非完整档 | 改的是已发布 CLI 的一个选项写法加一组诊断输出，面积只在 `DumpCommand`；按「不确定档位时走轻量档」处理 |
| 2026-09-06 | 状态置为 Implemented | 代码、测试、指南同批次落地；落地时按规则分配编号 0007（远端共享分支上的全局最大号为 0006） |
| 2026-09-06 | 不需要新增实现说明，也没有新术语进术语表 | 对外行为的全部约定已写进使用指南第六节；本次没有引入任何新概念 |
| 2026-09-06 | 顺带修正指南自身的一处笔误 | 开头引用的是「必须知道的四件事」，而该节实际标题是「五件事」；本次加到六条，一并订正 |
| 2026-09-06 | `diagnosticNotes` 收参数为 `Outcome` 结构体 | 六个平铺参数触发 SwiftLint 的 `function_parameter_count`（上限 5）；顺带让测试的构造点更易读 |
