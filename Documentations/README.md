# 文档索引

MachOObjCSection 的内部文档。新增或重命名任何文档都必须同步更新这份索引。

面向公众的文档（`README.md`、`LICENSE`）不在此目录，仍在仓库根目录，且使用英文。

## 目录

- [Evolutions/](Evolutions/README.md) —— 变更提案。一次实质改动一份，从调研到落地全生命周期。
- [Internal/](#实现说明) —— 实现说明。面向维护者，记录最终怎么实现、为什么这么实现、有什么降级。

## 提案

| # | 标题 | 状态 |
|---|------|------|
| [0001](Evolutions/0001-objc-rendering-and-indexing-downstreaming.md) | ObjC 渲染层与索引层下沉，并抽出两库共用的公共底座 | Implemented |
| [0002](Evolutions/0002-objc-machofile-genericization-and-cli.md) | ObjC 索引层泛型化到 MachOFile，并提供 objc-section CLI | Draft |
| [0003](Evolutions/0003-objc-relationship-tables-return-to-application.md) | ObjC 关系反向表移出索引层，归还应用 | Implemented |
| [0004](Evolutions/0004-strip-synthesized-setter-selector-fix.md) | 修正 stripSynthesizedMethods 漏剥 setter 的选择器拼写 | Implemented |
| [0006](Evolutions/0006-safe-objc-protocol-metadata-traversal.md) | 安全读取并有界遍历 Objective-C protocol metadata | In Review |

## 实现说明

| 文档 | 说明 |
|---|---|
| [ObjC 渲染层与索引层的实现说明](Internal/ObjCRenderingAndIndexingImplementation.md) | 0001 的配套。三个新 target 的分层与依赖方向、Linux 支持的真正障碍、锁的选型、事件通道合并，以及与提案不一致之处 |
