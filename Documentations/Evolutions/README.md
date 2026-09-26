# Evolution 提案

- **项目类型**: 库（源码分发）

本目录记录 MachOObjCSection 的所有实质性变更提案。一次改动一份文件，从前期调研到最终落地
都在同一份里原地更新，不另起 design / plan / report。

被否决的提案保留不删 —— 它是「当初为什么没这么做」的唯一记录。

## 状态说明

| 状态 | 含义 |
|---|---|
| `Draft` | 撰写中，尚未提交评审 |
| `In Review` | 开放讨论中 |
| `Accepted` | 已批准，可以开始实现 |
| `In Progress` | 实现进行中 |
| `Implemented` | 实现完成并已合并 |
| `Rejected` | 已否决（保留存档） |
| `Deferred` | 方向成立但延后 |
| `Withdrawn` | 作者撤回 |

## 提案列表

| # | 标题 | 状态 |
|---|------|------|
| [0001](0001-objc-rendering-and-indexing-downstreaming.md) | ObjC 渲染层与索引层下沉，并抽出两库共用的公共底座 | Implemented |
| [0002](0002-objc-machofile-genericization-and-cli.md) | ObjC 索引层泛型化到 MachOFile，并提供 objc-section CLI | Implemented |
| [0003](0003-objc-relationship-tables-return-to-application.md) | ObjC 关系反向表移出索引层，归还应用 | Implemented |
| [0004](0004-strip-synthesized-setter-selector-fix.md) | 修正 stripSynthesizedMethods 漏剥 setter 的选择器拼写 | Implemented |
| [0005](0005-adopt-frameworktoolbox-utilities.md) | 改用 FrameworkToolbox 的 Mutex 与字符串工具，删掉本地手搓的副本 | Implemented |
| [0006](0006-objc-api-diff-and-evolution.md) | ObjC API Diff 与多版本 Evolution 追踪 | Implemented |
| [0007](0007-dump-sections-spelling-and-empty-diagnostics.md) | 修正 dump 的 `--sections` 写法，并让空结果不再无声 | Implemented |
| [0008](0008-objc-export-status.md) | ObjC 类与实例变量的导出状态查询 | Implemented |
| [0009](0009-objc-section-release-automation.md) | 推版本 tag 即自动发布 objc-section | Implemented |
| [0010](0010-remove-objc-section-cli.md) | 移除 objc-section 命令行（并入 swift-section） | Accepted |
| [draft](draft-safe-objc-protocol-metadata-traversal.md) | 安全读取并有界遍历 Objective-C protocol metadata | In Review |
| [draft](draft-safe-relative-member-list-resolution.md) | 安全解析 Objective-C relative member list-of-lists | In Review |

0002 以 0001 为前置，两者共同构成「让 MachOObjCSection 具备与 MachOSwiftSection 对等的
渲染 / 索引 / 命令行能力」这一条完整路线。

0003 修订 0001 的范围判断（0001 保持原貌不改），并应先于 0002 落地 —— 它删掉的正是泛型化里
最麻烦的那部分，先删能让 0002 的面积小一圈。实际落地顺序即 **0001 → 0003 → 0002**，
这条路线到 0002 为止已经走完。
