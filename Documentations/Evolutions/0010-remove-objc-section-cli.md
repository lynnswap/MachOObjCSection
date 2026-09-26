# 0010 - 移除 objc-section 命令行（并入 swift-section）

- **状态**: Accepted
- **创建日期**: 2026-09-23
- **最后更新**: 2026-09-23

## 摘要

objc-section 并入 swift-section，成为 `swift-section objc` 子命令组（见 MachOSwiftSection 仓库的提案
[0036](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection/blob/next/Documentations/Evolutions/0036-objc-subcommands.md)，
已合入 swift-section 的 `next`）。本仓库是 p-x9/MachOObjCSection 的 fork，带着一个 fork 独有的命令行和
一条发布流水线，同步上游的成本太高。等 swift-section 带着这组子命令发版之后，本仓库删除 objc-section
及其发布流水线，只保留 ObjC 的各个库。

## 方案

**前置条件**：swift-section 已经发布包含 `objc` 子命令的版本。在那之前，本仓库不做任何改动。

**删除**：

- `Sources/objc-section/` 与 `Tests/ObjCSectionCommandTests/`。
- `Package.swift` 里的 `objc-section` 可执行产品与目标、`ObjCSectionCommandTests` 测试目标，以及只有
  命令行用到的 swift-argument-parser 和 Rainbow 两个依赖。
- `.github/workflows/release.yml` 与 `version-check.yml`。后者读取 `Sources/objc-section/Version.swift`，
  必须和命令行在同一个提交里删掉，否则 main 上的版本检查会报红。

**改写**：

- README 的「Command Line」一节改成几行说明，指向 `swift-section objc`。
- `Documentations/Guides/ObjCSectionCommandLine.md` 只删命令行部分（已搬到 swift-section 的
  `Documentations/ObjCCommandLine.md`）。写给库调用方的部分留下：泛型参数怎么推断、为什么不建议
  外部实现 `ObjCMetadataSource`、RW data 为什么不在泛型接口上、分析 cache 需要 MachOKit 0.52.101+。
  文件改成库的使用指南，文档索引同步更新。
- 术语表 fork numbering 条目去掉 `release.yml` / `version-check.yml` 的部分（版本号形状仍用于库的 tag）。
- 0009 的决策日志补一行：它建立的发布流水线由本提案退役。

**保留**：`ci.yml`（库的构建与测试）；已发布的 0.8.106 Release，它是本仓库唯一一个 objc-section
二进制；历史提案 0002 / 0006 / 0007 / 0009 保持原样。

删除之后，库的下一个版本照常按 fork 版本号打 tag，只是不再生成 GitHub Release。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-23 | Created as Draft | 用户原话：「我打算去掉objc-section集成到swift-section里面了，这个仓库是fork的，维护两边很麻烦」 |
| 2026-09-23 | 只搬命令行，ObjC 的库留在本仓库 | 用户选定 |
| 2026-09-23 | 等 swift-section 发版之后再删 | 用户选定；避免出现两边都拿不到新版 ObjC 命令的空窗 |
| 2026-09-23 | 使用指南不整份删除，只删命令行部分 | 写提案后发现指南里有一半是写给库调用方的（泛型参数、`ObjCMetadataSource`、RW data、MachOKit 版本下限），这些随库留下 |
| 2026-09-23 | Draft → Accepted，落地编号 0010 | 用户批准。本提案先合入记录决定；实现要等前置条件满足，即 swift-section 发布含 `objc` 子命令的版本（MachOSwiftSection 0036 已合入其 `next`） |
