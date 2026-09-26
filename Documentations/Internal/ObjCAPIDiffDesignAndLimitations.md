# ObjC API Diff — 设计与已知局限

> 面向维护者的实现说明。对应提案 [0006](../Evolutions/0006-objc-api-diff-and-evolution.md)。
> 记录 `ObjCDiffing` 模块（ObjC API 比对引擎）的架构、关键设计取舍，以及一组当前的
> 已知局限——大多数源于 ObjC metadata 本身携带的信息边界，而非实现取巧。
>
> 参考实现：MachOSwiftSection 的 `SwiftDiffing`
> （其设计文档 `ABIDiffDesignAndLimitations.md` / `ABIEvolutionDesign.md`）。本文只展开
> ObjC 侧**不同**的部分；与参考实现逐点一致的算法（三路匹配、first-wins keying、
> evolution 的逐版本矩阵、N == 2 与双侧 diff 的一致性保证）不重复论证。

## 概述

`ObjCAPIDiffer` 比对两个二进制的 ObjC API：把每个声明按其运行时身份
（类名 / 协议名 / category uniqueName / selector）建索引，对 classes、protocols、
categories 三个 bucket 做递归三路集合差分。diff 本身不接触 Mach-O——一旦
`ObjCAPISnapshotBuilder`（`ObjCInterface`）把索引结果组装成 `ObjCAPIModule`，
之后的一切都是纯值计算。

三个入口共用一套算法：live（`diff(old: ObjCAPIModule, new:)`，先冻结再比）、
document（`diff(old: ObjCAPISnapshotDocument, new:)`，带 provenance）、
frozen（`diff(old: ObjCAPISnapshot, new:)`，纯值）。

## 与 SwiftDiffing 的语义差异（有意为之）

| 维度 | SwiftDiffing | ObjCDiffing | 理由 |
|---|---|---|---|
| 身份 | remangle 后的 mangled symbol（`.mangled`/`.printed` 双 case + 回退诊断） | 命名空间字符串（`method:-foo:` 等），无回退路径 | ObjC 身份是纯名字，remangle 及其全部复杂度不存在 |
| function/method 换签名 | removed + added（换 mangled symbol = 换 ABI 入口点） | **modified**（selector 不变即同一入口，typeEncoding 进 payload） | ObjC 的派发身份是 selector 本身 |
| 容器 kind 变化 | 折入容器身份（struct↔class 报 removed+added） | superclass 作为**伪成员**（换父类报 modified，old → new 并列） | 类名是稳定身份，整类 removed+added 会淹没「其余成员未变」的信息 |
| 诊断通道 | 键碰撞 + remangle 回退两类 | 仅键碰撞一类 | 无 remangle；ObjC 侧碰撞的现实来源是 duplicate class（运行时允许） |
| 顶层 bucket | 8 个（types/protocols/4×extension/2×global） | 3 个（classes/protocols/categories） | ObjC 无 extension 拆分问题，无 global 声明 |

## 键格局（即持久化格式）

`ObjCAPIKey` 的命名空间字符串是 `ObjCAPISnapshotDocument` 的事实序列化格式，
**任何变更必须 bump `currentFormatVersion`**（当前 = 1）：

| 实体 | identityKey | payloadKey |
|---|---|---|
| method | `method:-<sel>` / `method:+<sel>` | `enc:<typeEncoding>`（协议成员追加 `\|optional:0/1`） |
| property | `property:-<name>` / `property:+<name>` | `attr:<normalized>`（剥 `V` 段；协议成员同上） |
| ivar | `ivar:<name>` | `enc:<typeEncoding>` |
| protocol 采纳 | `adopts:<name>` | = identity |
| superclass 伪成员 | `superclass` | `super:<name>`（root class 为空串） |
| 容器 | `class:` / `protocol:` / `category:` + 名字 | —（成员递归 diff） |

### 三个刻意排除的字段

- **`ObjCMethodInfo.imp`** —— 地址，逐次构建都变，进 key 会让一切都 modified。
- **`ObjCIvarInfo.offset`** —— non-fragile ABI 下由运行时滑动，且一处中插会级联
  modified 其后所有 ivar。类型变化（`enc:`）仍然可见；纯布局位移不可见（见局限 3）。
- **`ObjCClassInfo.instanceSize` / `.imageName` / `.version`** —— 派生值 / 环境值。

### property payload 为什么剥 `V` 段

`attributesString` 的 `V<ivarName>` 是合成 backing ivar 名，属实现细节：
它的变化在 ivar 轴上以 `ivar:_old` removed + `ivar:_new` added 的形式已经可见，
折入 property payload 只会把同一件事报两遍。剥除走解析后的
`attributes: [ObjCPropertyAttribute]` 过滤 `.ivar` case 再 `encoded()` 重组——
**不要**用逗号 split 原始串（类型段 `T@"NSDictionary<NSString *,NSNumber *>"`
里有引号内逗号）。

### 协议成员的 optionality 走 payload 不走 identity

required ↔ optional 迁移在同一 selector 上发生，identity 折入 optionality 会把它
错报成 removed + added。payload 折入后如实报 modified。同一版本内一个 selector
不会同时出现在 required 与 optional 组（runtime metadata 结构保证），所以无碰撞。

## 兼容性判定

基线规则（added → additive；removed / modified → breaking）之上只有一条
record 级 refinement：**协议新增 required 成员 → breaking**（现有 conformer 缺实现），
新增 optional 保持 additive。结构与参考实现的 `hasDefaultImplementation`
refinement 同构，同一函数（`ObjCMemberRecord.compatibilityOverride(old:new:)`）
被双侧 differ 与 evolution builder 共用，N == 2 时两条路径的 verdict 不可能分叉。

## 已知局限

### 1. ObjC 无访问控制 → 判定分不出公开 API 与私有实现

二进制里的每个 selector 地位相同。私有 helper 的重命名与公开 API 的删除都报
breaking，读者需自行结合语义判断。与参考实现「`@frozen` 不可恢复，一律按
resilient 处理」同属「宁可诚实保守，不可自信出错」的取舍。

### 2. 快照是「未过滤」的 metadata 事实，与渲染的 strip 语义无关

`ObjCInterfaceBuilder` 的 strip（剥合成访问器等）是渲染视图的关切；快照固定投影
完整模型，与 `ObjCGenerationOptions` 无关——否则同一二进制在不同选项下产出不同
baseline。后果：property 的 attribute 变化和它的合成 getter/setter 的 typeEncoding
变化可能同时上报，这是如实反映 metadata，不视为重复噪声。

### 3. ivar 纯布局变化不可见

offset 不折入 payload（见上），所以「类型不变、只有布局位移」的 ivar 变化不产生
任何报告。需要布局敏感比对时（对齐、打包变化），是未来的独立维度，不是把 offset
塞回 payload——那会把每次中插放大成整列表 modified。

### 4. 超类链成员不进本类容器

`ObjCClassGroup.info` 首元素是类自身，其余是超类链；快照只投影首元素。
继承来的成员属于超类自己的容器，重复投影会把一次超类变化放大成 N 个子类的变化。
代价：文件模式下超类链截断的那条既有限制（见 CLI 指南「必须知道的几件事」）
对 diff 无影响——diff 根本不看链。

### 5. 递归协议树只取第一层

`protocols` 数组是递归物化的树，快照只取第一层的 `name`（即直接采纳）。
间接采纳的变化由对应协议自己的容器报告。这也避免了把树序列化进 baseline 的
指数膨胀。

### 6. category 同名合并风险

category 身份是 `ClassName(CategoryName)`。同一二进制里对同一类声明两个同名
category 是运行时允许的（后果自负），会触发键碰撞诊断——first-wins 保留第一个，
Warnings 段列出被丢弃的。

## 测试结构

- `Tests/ObjCDiffingTests/` —— 纯值单元测试（45 个）：投影键格局、三路匹配、
  refinement、codec（round-trip / 缺版本头 / 版本不符 / 字节稳定）、evolution
  形状（presence 位图 / 缺口语义 / N == 2 一致性 / 标签解析）、两个 reporter 的
  整段文本断言。全程无 Mach-O、无 runtime。
- `Tests/ObjCInterfaceTests/ObjCAPISnapshotBuilderTests.swift` —— 进程内
  Foundation 镜像的冒烟：module 组装（own-declaration only）、快照确定性、
  自 diff 为空、经 document 往返。
- 手工端到端验证（2026-08-20）：macOS 15.5 vs 26.5.2 两份 dyld shared cache 的
  CoreLocation，`snapshot` → `diff`（644 行报告，捕捉到 CLBeaconRegion 等类的
  真实属性删除）→ `evolution --summary-only`（226 added · 197 removed ·
  67 modified · API-breaking）→ `--fail-on-breaking` 退出码 1 / 自 diff 退出码 0。

## 与提案的差异

无实质偏离。提案「详细设计」中的类型与签名即最终实现；`ObjCAPIDiffer` 额外公开了
`diffMembers(old:new:)` 作为测试接缝（参考实现同款）。
