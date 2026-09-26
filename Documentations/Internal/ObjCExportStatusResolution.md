# ObjC 导出状态的判定 — 判据、边界与实测

> 面向维护者的实现说明。对应提案
> [0008](../Evolutions/0008-objc-export-status.md)。
> 记录 `ObjCExportIndex` / `ObjCExportStatus` 的判据来源、三处反直觉的边界，
> 以及建索引的实测开销。
>
> 参考实现：MachOSwiftSection 的 `ExportStatus`——该项目的三份提案，0008 给输出加
> `// not exported` 标注、0016 加 `--exported-only` 过滤、0024 把标志下沉到声明模型。
> （那个 0008 是 MachOSwiftSection 的编号，与本项目的 0008 无关。）
> 本文只展开 ObjC 侧**不同**的部分。

## 概述

`ObjCExportIndex` 遍历一次镜像的 export trie，留下两批名字：ObjC 类的
`_OBJC_CLASS_$_<类名>` 与实例变量的 `_OBJC_IVAR_$_<类名>.<ivar 名>`，前缀在建表时
就剥掉。之后每次查询是一次哈希查找，返回三态的 `ObjCExportStatus`。

**它回答的是链接可见性，不是访问级别。** ObjC 没有 `public` / `private` 可供恢复，
export trie 能说的只有「dyld 能不能从别的镜像解析到这个符号」。

## 为什么只有类和实例变量有入口

这是本文最需要留档的一条 —— **协议与分类不是漏做，是判不了**。

实证取 dyld shared cache 里的 AppKit 与磁盘上的 `DVTKit.framework`（Xcode 私有框架，
非 cache），用 `dyld_info -exports` 与 `nm -m` 对照：

| 对象 | 符号形态 | AppKit（cache） | DVTKit（磁盘） | 判据 |
|---|---|---|---|---|
| 类 | `_OBJC_CLASS_$_<类名>` | trie 里 667 个 | 定义 167 个类：160 个 `external`（全在 trie），7 个 `non-external` | **成立** |
| 实例变量 | `_OBJC_IVAR_$_<类名>.<ivar 名>` | trie 里 230 个 | 911 个 ivar 符号：59 个 `external`（全在 trie），852 个 `private external` | **成立** |
| 元类 | `_OBJC_METACLASS_$_<类名>` | 667 个 | 160 个 | 成立但冗余，两处都与类符号数完全相等且成对，故不做 |
| 协议 | `__OBJC_PROTOCOL_$_<协议名>` | trie 里 **0 个** | 82 个协议符号**全部**为 `non-external (was a private external)` | **不成立** |
| 分类 | 无对应符号 | — | — | **不成立** |

协议那一行是**编译器行为，不是二进制被 strip**：clang 发射 ObjC 协议符号时一律标
`.private_extern`，链接器合并后 dyld 不导出（运行时经 `objc_getProtocol` 按名字查找，
不走符号解析）。所以在任何二进制上都判不了，与 Swift 的 protocol descriptor（`…Mp`，
正常导出符号）截然不同。

与其给一个永远返回「不适用」的函数，API 里干脆没有这个入口 —— 调用方在编译期就会
发现，而不是在运行期收到一个永远无意义的值。

DVTKit 那 7 个未导出的类，说明这个事实的实际用途：

```
_OBJC_CLASS_$__DVTNSAccessibilityIndexedMockUIElement
_OBJC_CLASS_$__DVTNSPathControlAuxiliary
_OBJC_CLASS_$__TtC6DVTKit35DVTPathControlNavigationPopoverItem
_OBJC_CLASS_$__TtCC6DVTKit25DVTTextCompletionListView13DebugTagLayer
```

前两个是 `_` 前缀的 ObjC 私有类，后两个是 Swift 定义的 `internal` 类。**Swift 类不需要
任何特殊处理**：它的符号名就是前缀直接拼 metadata 里那个已重整的运行时名，字符串拼接
就对得上。这是 ObjC 侧比 Swift 侧简单的地方 —— Swift 那边要从 name node 重整出 `…Mn` /
`…Mp`，还得为 constrained extension 留一个「重整不可信」的分支，所以它是四态，这里是
三态。

## 三处反直觉的边界

### 一、查询是 per-image 的，问错镜像会得到误导性的「未导出」

`NSArray` 是再公开不过的类，但对 Foundation 查它，答案是 `notExported` —— 因为
**`NSArray` 由 CoreFoundation 定义并导出**（toll-free bridging 的缘故，`NSDate`、
`NSURL`、`NSDictionary` 同理）。Foundation 的 trie 里根本没有它。

这个答案是对的：问题是「这个镜像导出了什么」，不是「这个类在哪导出」。但它意味着
**调用方只能拿本镜像自己定义的类去查**。从某个类的 metadata 里读出的超类名、协议采纳
里的类名，经常属于别的镜像，拿去查会得到一串毫无意义的负面答案。

这条由测试 `classDefinedInAnotherImageReadsAsUnexportedHere` 钉住（Foundation 查
`NSArray` 得 `notExported`，CoreFoundation 查得 `exported`）。

### 二、导出符号为零算「无信息」，不算「全都没导出」

`.o` 目标文件没有 export trie、dyld shared cache 镜像的 linkedit 读失败、以及一个
真的用 `-exported_symbols_list` 导出了零个符号的 dylib，从这一层看完全一样：
`exportedSymbols` 返回空数组。

三者归为 `imageHasNoExportInformation`。代价是无法判定「确实什么都不导出」的镜像，
这近乎假想；收益是不会在读取失败时把整个镜像的类**静默地全部标成内部实现类**。这与
MachOSwiftSection 提案 0016 的原则一致：拿不到证据就不裁决，过滤绝不靠猜。

### 三、不用 `ExportTrie.search(byKeyPrefix:)`

MachOKit 提供了前缀搜索，看起来正好能一次捞出 `_OBJC_CLASS_$_` 打头的所有项。**不用**，
理由是正确性：`TrieTreeProtocol._search(byKeyPrefix:)` 沿 trie 下行时用
`children.first(where:)`，前缀消耗完之后若有**多个** child 仍以该前缀开头，只取其中一个，
其余分支整个丢掉。能否取全取决于 trie 恰好在 `_OBJC_CLASS_$_` 处有节点边界 —— 常见的
export trie 生成器确实会把公共前缀压成一层，但「通常正确」不是能拿来建判据的东西。漏一个
分支就是把一批导出的类静默报成内部类。

改为遍历一次 `machO.exportedSymbols` 分拣。实测（见下）这条路 95% 的开销在 MachOKit 解析
trie 本身，分拣只占 1 毫秒左右，所以前缀搜索即便正确也省不下什么。

## 实测：建索引的开销

macOS 26.x / arm64e，dyld shared cache 内的镜像，10 次取中位数：

| 镜像 | 建索引 | 其中 `exportedSymbols` 本身 | 导出符号总数 | 类符号 | ivar 符号 |
|---|---|---|---|---|---|
| Foundation | 40.9 ms | 38.7 ms（94.6%） | 15509 | 397 | 98 |
| AppKit | 23.2 ms | 22.2 ms（95.7%） | 8771 | 667 | 230 |
| SwiftUI | 51.4 ms | 49.2 ms（95.8%） | 19471 | 13 | 0 |

分母：同一台机器上 AppKit 走一遍 `ObjCInterfaceIndexer.prepare()` 是 **27.2 秒**
（2573 个类）。建索引占 **0.085%**，即无条件建表是免费的，不需要开关也不需要延迟构建。

两条附带结论：

- **瓶颈在 MachOKit 解析 trie**（95%），不在本模块的分拣循环。要再优化只能换读取方式，
  而唯一现成的换法（前缀搜索）有上面那个正确性问题。
- **纯 Swift 框架的索引近乎空表**：SwiftUI 只有 13 个 ObjC 类符号、0 个 ivar 符号。
  这是正常的，不是读取失败 —— 区分二者靠的是 `exportedSymbols` 总数不为零。

Set 的规模跟着类符号数走（百量级的短字符串），内存不构成考量。

## 测试怎么钉住这些

`Tests/ObjCMetadataSourceTests/ObjCExportIndexTests.swift`，九条，其中三条是主力：

- **地址交叉验证**（`exportedClassSymbolSitsAtClassRecordAddress`）：断言「符号查得到」是
  同义反复 —— 索引本来就是从这些符号建的。真正有效的是断言导出项的地址**等于该类记录
  自己的地址**，它会在前缀多剥/少剥一个字符、名字拼装错、两种 offset 口径混用时变红。
- **file / image 双模式一致**（`fileModeAndImageModeAgreeOnEveryClass`）：同一个 Foundation，
  一次作为 cache 里的 `MachOFile`、一次作为进程内的 `MachOImage`，逐类比对。`MachOFile`
  读 cache 镜像的 linkedit 走的是完全不同的路径（`_fileSliceForLinkEditData` 的重定向），
  这条测试是它没坏的唯一保证 —— 而 cache 镜像正是 RuntimeViewer 的主力场景。
- **ivar 反向验证**（`exportedIvarSymbolsNameDeclaredIvars`）：把 trie 里每个
  `_OBJC_IVAR_$_<类>.<ivar>` 拆开，要求镜像确实在**那个类**上声明了这个 ivar。它同时
  钉住了「`ObjCClassInfo.ivars` 只含本类自己的 ivar」这条上游假设 —— 若上游哪天开始把
  继承来的 ivar 也算进去，符号与类的对应关系就不再成立。

另有一条 `exportTrieSymbolNamesCarryLeadingUnderscore` 钉住 MachOKit 交还的符号名带前导
下划线。若某个 MachOKit 版本开始剥它，所有查询会静默落空、所有类读成 `notExported` ——
没有崩溃也没有空结果可供察觉，只有这条测试会红。

## 本轮不做的

- **CLI 一个字节没动**。MachOSwiftSection 提案 0008 的 `// not exported` 标注与 0016 的
  `--exported-only` 过滤都没有 ObjC 对应物，本轮只铺事实层。
- **不进 `ObjCAPISnapshot` / `ObjCDiffing`**。导出状态是符号化状态，不是 API 事实；
  加字段还会破坏既有 baseline 的 `formatVersion` 契约。
- **没有进程级缓存**。本库没有 MachOSwiftSection 那套 `SharedCache` 基座，
  `ObjCExportIndex` 是值类型，生命周期由调用方掌握。
