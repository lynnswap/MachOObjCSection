# 术语表

MachOObjCSection 专有名词与约定用法。

跨项目通用的术语收录在全局术语表（iCloud Global 镜像的 `Documentations/Glossary.md`），
本表只收本项目特有的，不重复登记。与 diffing 相关的三条通用术语在全局表：
**baseline snapshot（基线快照）**、**identity key 与 payload key（身份键与载荷键）**、
**lineage（生命线）**。

提案或专题文章引入新术语时，**同批次**登记进本表。

## 术语

按英文名 / 标识符字母序排列。

### fork numbering（fork 版本号）

本仓库是 `p-x9/MachOObjCSection` 的 fork，自己的发布版本号写作
`<上游 major>.<上游 minor>.1NN`（如 `0.8.106`）：前两段跟随所基于的上游版本，第三段从 100 起
逐次递增，与上游自己的补丁号（`0.8.2` 之类）永不相撞。这个号同时是 SwiftPM 的包版本（下游
`from:` / `exact:` 依赖的就是它）和 `objc-section --version` 的输出。发布流水线**只认这个形状**：
`release.yml` 的 tag 过滤只匹配它，所以同步过来的上游 tag 不会触发发布；`version-check.yml`
拒绝不符合它的 `BundledVersion.value`，免得打了 tag 却没有任何报错地不发布。

- **主要出现在**：`Sources/objc-section/Version.swift`、`.github/workflows/release.yml`、`.github/workflows/version-check.yml`
- **延伸阅读**：[提案 0009](Evolutions/0009-objc-section-release-automation.md)

### key namespace（键命名空间）

`ObjCAPIKey` 的前缀约定：`class:` / `protocol:` / `category:`（容器）、
`method:-` / `method:+`（实例 / 类方法 + selector）、`property:-` / `property:+`、
`ivar:`、`adopts:`（直接协议采纳）、`superclass`（伪成员）。前缀保证不同种类的成员
永不碰撞，同时它就是 baseline 的事实持久化格式——**任何变更必须 bump
`ObjCAPISnapshotDocument.currentFormatVersion`**。完整格局表见
[实现说明](Internal/ObjCAPIDiffDesignAndLimitations.md)。

- **主要出现在**：`Sources/ObjCDiffing/ObjCAPIKey.swift`、`ObjCMemberRecord.swift`
- **延伸阅读**：[提案 0006](Evolutions/0006-objc-api-diff-and-evolution.md)

### ObjCAPIModule 与 ObjCAPISnapshot 之别

同一份声明数据的两种形态，不可混用：**module** 是 live 输入（持有 ObjCDump 的
`*Info` 值，含递归协议树，不可序列化），**snapshot** 是冻结产物（只剩键与签名的纯值，
`Codable`，即 baseline 的内容）。`ObjCAPIDiffer.snapshot(of:)` 是两者之间唯一的桥，
也是全模块唯一接触模型知识的地方。

- **主要出现在**：`Sources/ObjCDiffing/ObjCAPIModule.swift`、`ObjCAPISnapshot.swift`

### ObjCExportStatus（导出状态）

一个 ObjC 类或实例变量的**链接可见性**——它的符号（`_OBJC_CLASS_$_<类名>` /
`_OBJC_IVAR_$_<类名>.<ivar 名>`）在不在镜像的 export trie 里。三态：`exported` /
`notExported` / `imageHasNoExportInformation`，最后一态是**镜像级**的「无从判断」
（`.o` 目标文件、读不到 linkedit 的镜像），绝不可当作「未导出」使用。

三条必须记住的边界：

1. **这是符号表事实，不是访问级别。** ObjC 没有 `public` / `private` 可供恢复，
   能说的只有「dyld 能不能从别的镜像解析到这个符号」。
2. **协议与分类判不了，不是漏做。** ObjC 协议符号一律 `private extern`，从不进
   export trie；分类没有自己的符号。所以 API 里没有这两个入口。
3. **查询是 per-image 的。** 对 Foundation 查 `NSArray` 得到 `notExported`——该类由
   CoreFoundation 定义并导出。只能拿本镜像自己定义的类去查。

- **主要出现在**：`Sources/ObjCMetadataSource/ObjCExportStatus.swift`、
  `Sources/ObjCMetadataSource/ObjCExportIndex.swift`
- **延伸阅读**：[实现说明](Internal/ObjCExportStatusResolution.md)、
  [提案 0008](Evolutions/0008-objc-export-status.md)

### pseudo-member（伪成员）

不是真实成员、但被投影成成员记录参与 diff 的容器属性：目前只有 `superclass` 一个。
这样换父类报「类被 modified（old → new 并列）」而不是「整类 removed + added」，
保住「其余成员并未变化」的信息。

- **主要出现在**：`ObjCMemberRecord.makeSuperclass(superclassName:)`

### uniqueName

category 的索引与显示身份：`ClassName(CategoryName)`（如 `NSString(MyAdditions)`）。
category 自己的 `name` 不含目标类，同名 category 可以挂在不同类上，所以一切按名索引
的地方（索引器、diff 的容器键）用的都是 uniqueName。定义在 `ObjCMetadataSource`
（0006 起，从渲染层下沉），一行拼接，两处漂移的风险靠单一定义消除。

- **主要出现在**：`Sources/ObjCMetadataSource/ObjCDump+ModelDerivations.swift`
