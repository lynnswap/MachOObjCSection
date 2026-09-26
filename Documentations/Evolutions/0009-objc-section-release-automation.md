# 0009 - 推版本 tag 即自动发布 objc-section

- **状态**: Implemented
- **创建日期**: 2026-09-23
- **最后更新**: 2026-09-23
- **配套文档**: [objc-section 使用指南](../Guides/ObjCSectionCommandLine.md)（「安装与构建」一节）

## 摘要

照搬 MachOSwiftSection 的发布流水线：推一个版本 tag，GitHub Actions 就编出 `objc-section`
的 x86_64 + arm64 通用二进制、建 GitHub Release，发布说明取 `Changelogs/<版本>.md`。此前本仓库
只打 tag、从未发过 Release，想用 `objc-section` 只能自己从源码编。顺带换掉从上游继承、在本
fork 上根本跑不起来的 `ci.yml`。

## 方案

**发版契约**与 swift-section 相同：`Sources/objc-section/Version.swift` 的 `BundledVersion.value`
是唯一的版本来源；改它的同时补 `Changelogs/<value>.md`，合进 main 后打同名 tag。

| 文件 | 作用 |
|---|---|
| `.github/workflows/release.yml`（新） | 推 tag → 查 changelog 在不在、查版本号与 tag 是否一致 → 分别编 x86_64 与 arm64 → `lipo` 合成并 ad-hoc 签名 → 打包 `objc-section-macos-universal.zip` → `gh release create` |
| `.github/workflows/version-check.yml`（新） | 推送或 PR 到 main 时检查：版本号符合 fork 版本号的形状，且正式版有对应的 changelog |
| `.github/workflows/ci.yml`（改写） | macos-26 + Xcode 26.6 上 `swift build`，再 `swift test --skip MachOObjCSectionTests`；删掉 Linux 任务 |
| `Changelogs/0.8.106.md`（新） | 第一个走这条流水线的版本 |

与 swift-section 的差异，前三条都来自「本仓库是 fork」：

1. **tag 过滤只匹配 fork 版本号**（`[0-9]+.[0-9]+.1[0-9][0-9]*`，形状见术语表 fork numbering）。
   origin 上已经有 `0.8.0`、`0.8.1` 两个上游 tag；照抄 `'*'` 的话，下次同步上游 tag 就会触发一次
   必然失败的发布。代价是版本号一旦不符合这个形状，打了 tag 也会**静默不发布**，所以
   `version-check.yml` 在 main 上先把它拦下。
2. **`GH_REPO` 钉死为 `github.repository`**。本地 clone 同时有 `origin` 和 `upstream` 两个 remote，
   直接跑 `gh` 默认对着上游 p-x9（实测 `gh release list` 列出的全是上游的 Release）。CI 的 checkout
   只有 origin，钉死是防御性的。
3. **`ci.yml` 整体改写**。继承来的版本用 Xcode 16.2，读不了 `swift-tools-version: 6.2` 的清单；
   它的 Linux 任务也注定失败——本 fork 在 Linux 上早就编不过（见
   [ObjC 渲染层与索引层的实现说明](../Internal/ObjCRenderingAndIndexingImplementation.md)
   的 Linux 一节）。启用 Actions 后它每次推送都会报红。`MachOObjCSectionTests` 在 `setUp()` 里读
   维护者本机路径下的样本，换台机器必然失败，CI 里跳过。
4. 小处：`actions/checkout` 用 v7（swift-section 用的 v4 已经报 Node 20 弃用警告）；Xcode 统一
   26.6；tag 名经环境变量而不是 `${{ }}` 直接拼进 shell。

**前置条件，须维护者在 GitHub 网页上操作一次**：GitHub 默认不在 fork 上运行工作流。本仓库的
`ci.yml` 自 2025-09 起就在，main 推送过多次，Actions 运行记录仍是 0 条。须在仓库的 Actions 页
手动启用，而且必须早于第一次推 tag——否则 tag 推上去什么也不会触发，只能删 tag 重推。

**本地验证**（`git archive HEAD` 导出到临时目录、只用远程依赖，模拟 CI 的干净 checkout）：两种
架构的 release 构建共约 2 分钟，`lipo` 合成与 ad-hoc 签名成功，`--version` 正常；
`swift test --skip MachOObjCSectionTests` 146 个测试全部通过，退出码 0。runner 上的首次实跑要等
启用 Actions 之后确认。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-23 | Created as Draft | 用户原话：「模仿一下swift-section的CI，发新版本时自动发布objc-section」 |
| 2026-09-23 | 同批准备 0.8.106：升 `Version.swift`，写 `Changelogs/0.8.106.md` | 用户选定。`version-check.yml` 一上线，main 上的 0.8.105 没有 changelog 会立刻报红；0.8.105 的 tag 早于流水线，补写 changelog 也换不来 Release |
| 2026-09-23 | `ci.yml` 改写为 macOS 26 构建 + 测试，不删除 | 用户选定 |
| 2026-09-23 | Accepted → In Progress | 用户在澄清提问中选定上述两项，对方案没有异议 |
| 2026-09-23 | In Progress → Implemented，落地编号 0009 | 用户审阅 changelog 后同意提交。runner 上的首次实跑以推 `0.8.106` tag 为准 |
| 2026-09-23 | 不另写实现说明；使用指南只更新「安装与构建」一节 | 不直观的决定（tag 过滤、`GH_REPO`、跳过的测试、没有 Linux 任务）都写在工作流的注释里，就在会被改动的那一行旁边；另写一篇只会复述 YAML |
| 2026-09-23 | 新术语 fork numbering 登记进项目术语表 | 这个版本号形状此前只出现在 `Version.swift` 的一句注释里，现在 tag 过滤与版本检查都依赖它 |
