# 0007 - 安全解析 Objective-C relative member list-of-lists

- **状态**: In Review
- **作者**: Kazuki Nakashima
- **创建日期**: 2026-08-19
- **最后更新**: 2026-08-19
- **关联提案**: [0006](0006-safe-objc-protocol-metadata-traversal.md)
- **配套文档**: 无 —— 本文是本批 owner、SPI 与验证契约的正本

## 摘要

Objective-C runtime 对 method、protocol、property 使用同一种 `relative_list_list_t` ABI。
loaded reader 应按 outer table 顺序遍历，以每个 entry 自己的 image index 查询 loaded bit，
静默跳过 unloaded entry。旧 method/property dump path 却按 class owner image index 只找第一项；
owner entry 不存在时又把 relative representation 当作 regular list fallback，最终静默输出空数组。

本提案把 0006/Issue #62 的 outer parser 升格为中立 owner，并让 protocol、method、property
共享 count、advertised stride、byte budget、range、entry offset、loaded-state 与 target image
解析。inner method/property decoder 仍各自拥有 list kind 与 entry layout。

## Consumer contract

普通 consumer 的 `info(...)` / `ObjCClassInfo` surface 不变。Diagnostics SPI consumer 可在同一次
class read 中分别处理既有 protocol diagnostics 与新增 member-list diagnostics：

```swift
let result = objcClass.readInfo(in: machO, options: .headerDump)
render(result.value)

for diagnostic in result.diagnostics {
    reportProtocolDegradation(diagnostic)
}
for diagnostic in result.memberListDiagnostics {
    reportMemberDegradation(diagnostic)
}
```

`ObjCProtocolDiagnostic` 与 `diagnostics` 的类型/cases 不变，避免破坏已有 exhaustive consumer。
新增 additive SPI `ObjCMemberListDiagnostic`，payload 包含 class name、instance/class ×
method/property 四种 kind、outer list offset、table/entry location 与 typed structural failure。

## Owner map

| invariant | owner |
|---|---|
| outer table count/stride/budget/range | neutral relative-list core |
| entry offset 与 source/address 解析 | neutral relative-list core |
| loaded/unloaded/unavailable 判定顺序 | `DyldCacheLoaded` + neutral core |
| method entry kind/size | `ObjCMethodList` adapter |
| property entry size | `ObjCPropertyList` adapter |
| ordered flatten 与 kind attribution | `ObjCDump` single-pass fold |
| warning 文案、persist/cap | downstream Diagnostics SPI consumer |

## 状态与顺序

safe outcome 用类型区分：

- `.absent`：field 为 0；
- `.failure`：outer table 整体不可读；
- `.entries([])`：合法空表或全部 unloaded；
- `.entries([resolved, failure, resolved])`：单个 loaded entry 失败但 sibling 保留。

unloaded 判定发生在 displacement、pointer、inner header 读取之前。同一 image index 的多个 entry
不会 deduplicate。relative representation 一旦确认，empty/failure 都不会 fallback 到 regular list。
flatten 保持 outer list 顺序与每个 inner list 的成员顺序，不用 set/dictionary 重排。

## Safety boundary

outer 与每个 resolved inner list 在 legacy `methods(in:)` / `properties(in:)` 前验证：

1. header 完整可读；
2. count 可 exact 转换；
3. count 为 0 时，不验证未使用的 entry size/alignment，并作为合法空 list 成功；
4. 非空 list 的 address/offset 满足对应 method/property entry 的 alignment；header 本身使用 unaligned load；
5. 非空 list 的 entry size 与 method kind / target bitness 或 property bitness 一致；
6. `count * entrySize` 不 overflow，且不超过 65,536 entries / 512 KiB；
7. 完整 file/image table range 可读。

本提案保证 relative outer table 和 inner member table 的结构安全。不扩张到每个 method/property
内部 C string pointer 的 hostile-input 完整 hardening，也不声称整个 member parser 已全面 hardened。

## Source compatibility

以下既有 public low-level API 保留 signature：`RelativeListListProtocol`、
`ObjCMethodRelativeListList`、`ObjCPropertyRelativeListList`、
`methodRelativeListList/propertyRelativeListList`。public plural projection 改由 safe outcome 的
resolved entries 提供；failure 仍按旧 public contract 降级为省略。header-generation path 使用
internal typed outcome，不调用会在 probe 前 `.pointee` 的旧 query。

## 测试计划

- owner entry 不存在；
- mixed loaded/unloaded，且 unloaded offset 为 poisoned address；
- duplicate image index 与 multiple loaded lists；
- `good / malformed / good` 的 sibling 保持；
- all-unloaded、unknown load state、file all-loaded mode；
- outer stride/count/range 与 inner entry-size/count/range boundaries；
- count 为 0 且未使用 entry size 为 0/flags-only 的合法空 method/property list；
- method selector/property name 的 outer+inner 顺序；
- instance/class method/property 四种 diagnostic kind；
- Diagnostics SPI compile consumer；
- 0006 protocol safety suite、safe full suite、release 与 Apple platform cross-builds。

## 决策日志

| 日期 | 变更 | 说明 |
|---|---|---|
| 2026-08-19 | Created / In Review | Issue #65；从 protocol reader 抽取 neutral outer owner，保留 inner decoder 分工与既有 public surface |
| 2026-08-19 | additive member SPI | 不给 `ObjCProtocolDiagnostic` 增加 member case；已知 consumer 的 exhaustive switch 保持源码兼容 |
| 2026-08-19 | empty-list contract | 根据 watchOS 27 CoreFoundation runtime fixture，count 为 0 时不验证未使用的 entry size/alignment |
