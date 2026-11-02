# 功能差距分析（对标市面阅读 App）

> 分析对象：小浣熊阅读（legado-ios v0.1.14，build 20）
> 对标样本：微信读书、QQ 阅读、掌阅、多看、番茄小说、七猫小说，以及同源的开源安卓版 Legado 3.0（gedoor/legado、LegadoTeam/legado）
> 口径：本项目现状逐条来自仓库源码核对（`Sources/LegadoCore`、`App/Features`、`App/RootTabView.swift`、`docs/REMOTE_STORAGE.md`、`CHANGELOG.md`）；对标功能来自各家公开版本说明与横评资料。

---

## P0 实施进展（2026-11-02）

以下记录本轮实现；后文矩阵保留最初分析时的基线，不再代表这些功能的当前状态。

| 项目 | 本轮实现 | 使用与边界 |
| --- | --- | --- |
| P0-1 划线、笔记、导出 | SQLite 笔记仓库；分页选文、滚动段落与 EPUB 选文菜单；五色高亮、笔记编辑删除、按书/日期分组、Markdown 导出 | 字符位置使用 UTF-16，辅以原文锚点；EPUB 保存 locator 并以 Readium decoration 展示 |
| P0-2 备份与恢复 | 本地 ZIP 导出、合并/覆盖恢复；SQLite 全包事务、规则和设置补偿回滚；RSS、阅读偏好、本地 TXT/EPUB 原文件；WebDAV/S3/Dropbox 备份上传与下载 | Android 文件名兼容已有自动识别，使用合成备份验证书源与书架；尚未覆盖各版本真实备份包。书源未知字段随原模型保留；其他 Android 专有字段与本地文件路径不保证可迁移 |
| P0-3 全书/全库搜索 | FTS5 trigram 索引、1/2 字短词回退、缓存写入索引、本地全文和已有缓存补建；阅读器“本章/全书”、书架“全库正文搜索”、命中位置跳转 | 不自动下载尚未缓存的在线正文；查询上限 500 章。尚未完成 10 万段落的性能基线 |
| P0-4 扩大同步范围 | 书源、替换规则、TXT 目录规则、书签、笔记、阅读记录、RSS、TTS、规则订阅按命名空间同步 | 每设备不可变快照、LWW 时间戳、删除墓碑、传输期间本地修改保留；本地书笔记按原文件摘要重映射。登录态、Cookie 与远端凭据不参与同步 |
| P0-5 更新通知 | 通知权限开关、免打扰时段、合并章节提醒、未读更新角标、后台刷新注册与通知返回书架 | 后台执行时机由 iOS 决定；真机通知权限、后台调度和免打扰体验仍需实测 |

验证使用临时数据库与自造内容，不读取个人书架。完整 Swift 回归覆盖核心及页面模型；模拟器交互回归检查分页与滚动阅读的笔记入口。备份不包含 Keychain 凭据、Cookie、章节缓存、自定义字体或背景图片文件。可选的加密、定时备份和保留份数尚未实现。

本轮验证结果：`swift test --disable-sandbox` 共 426 项通过（31 项 XCTest、320 项核心 Swift Testing、75 项页面模型测试）；模拟器阅读布局与 EPUB 集成测试 13 项通过；新增选文笔记 UI 测试 1 项通过，覆盖分页和滚动两种模式。高亮绘制测试检查不同字号、重复原文定位、图像确实变化，以及原有文本布局保持不变。

---

## 一、结论摘要

一句话：**"读"的部分做得比 Android 原版更细（排版、EPUB 原排版、纸页翻页、远端同步），"管"和"记"的部分还缺一条完整链路。**

三个最关键的缺口（用户会立刻感知到）：

1. **没有划线/笔记/想法，也没有书摘导出** —— 微信读书、掌阅、番茄、甚至 Android 版 Legado 都有；这是"读完之后什么也留不下"的硬伤。
2. **没有一键备份/恢复** —— 书源、替换规则、TTS 配置、书签、统计散落在设备上，换机或重装等于重来；Android 版 Legado 的备份（含加密 zip、WebDAV 定时备份）是其最被依赖的功能之一。
3. **搜索只到"本章"，同步只到"书架+进度"** —— 全书搜索、全库搜索缺失；`REMOTE_STORAGE.md` 明确写了书源、规则、Cookie、书签、统计**不参与同步**，多设备用户会直接踩坑。

---

## 二、本项目现状盘点（源码核对）

### 1. 书架与书籍管理
| 已具备 | 位置 |
| --- | --- |
| 列表/网格、自定义分组（排序、显隐、批量归组）、书架阅读进度条、章节更新检查与更新数提示、换源、移出书架 | `App/RootTabView.swift`（`BookshelfView`）、`Books/BookLibraryModel.swift` |
| 本地 TXT / EPUB 导入、重命名、删除、已缓存正文导出为 TXT、远端下载并入书架 | `Activity/FileManagementView.swift`、`LocalBook/LocalBookService.swift` |
| 书架+分组+阅读进度跨设备同步（WebDAV / S3 / Dropbox） | `Remote/BookshelfSync.swift`、`docs/REMOTE_STORAGE.md` |

### 2. 阅读器
- 排版：字号、行距、字重、段首缩进、两端对齐、下划线、标题模式、页眉/页脚 6 个槽位自定义、背景图片、自定义字体导入、8 套预设主题 + E-Ink + 水墨江湖
- 交互：仿真纸页对折翻页 / 覆盖 / 无动画、点击区域可配（9 宫格）、长按菜单、中央点击区放大、屏幕方向锁定、常亮、隐藏状态栏与 Home 指示条、亮度手势
- 功能：目录（搜索/倒序/卷）、书签、**本章**正文搜索、替换净化、换源、章节正文编辑、自动阅读（连续滚动 + 翻页间隔）
- 朗读：系统 TTS + 多套 HTTP TTS 引擎，语速/音色/按页/跨章连播/媒体按键/唤醒锁/音频焦点/剩余时长
- EPUB：Readium 原书排版、目录、书签、翻页与滚动、主题字号、位置恢复、插图查看、切回文字模式
- 相关文件：`Reader/ReaderView.swift`、`Reader/ReaderAppearance.swift`、`Reader/ReaderSpeechController.swift`、`Reader/EPUBReaderView.swift`、`TTS/HttpTTSManagementView.swift`

### 3. 书源 / 规则 / 搜索
- 书源：JSON / 文件 / URL / 二维码（相机扫码已实现，权限缺失时才降级提示）导入，分组、批量删除、启用停用、分组内查看、语法高亮编辑器、调试器、WebView 登录、单源测试与搜索、导出
- 规则：替换净化（编辑 + 实时测试 + 导入导出）、TXT 目录规则、规则订阅与自动更新
- 搜索：多书源并发、结果陆续展示、有效结果缓存、同书多源合并、搜索历史
- 发现：按书源的分类 / 榜单浏览
- 相关文件：`Sources/LegadoCore/Sources/*`、`Sources/LegadoCore/RuleEngine/*`、`Search/SearchViewModel.swift`、`Explore/ExploreView.swift`

### 4. 设置 / 统计 / 诊断
- 设置：外观（跟随系统/浅色/深色/E-Ink/水墨）、阅读设置、主题、在线朗读、书签总览、阅读记录、文件管理、远端存储、网络（UA/全局代理/自定义 Hosts/超时/证书兼容/缓存上限）、日志诊断、数据库整理、网页缓存清理
- 统计：今日时长、累计时长、阅读书籍数、近 7 天、连续天数、7 日柱状图、阅读记录列表
- 相关文件：`App/RootTabView.swift`（`SettingsView`）、`Settings/OtherSettingsView.swift`、`Activity/ReadingStatisticsView.swift`

### 5. 系统能力使用情况（grep 全仓）
| 系统能力 | 是否使用 |
| --- | --- |
| `UNUserNotification`（本地/远程通知） | **未使用** |
| `WidgetKit`（小组件） | 未使用 |
| `ActivityKit`（实况活动） | 未使用 |
| `AppIntents` / Siri / 快捷指令 | 未使用 |
| `CoreSpotlight`（聚焦索引） | 未使用 |
| `CloudKit` / iCloud 文档 | 未使用 |
| Share Extension（系统分享接收） | 未使用 |
| `NavigationSplitView` / `horizontalSizeClass`（iPad 分栏） | 未使用 |

---

## 三、差距矩阵

图例：✅ 已有且完善 ｜ 🟡 有但不完整 ｜ ❌ 缺失

### A. 阅读与记录（内容消费侧）

| 能力 | 市面标杆 | 本项目 | 说明 |
| --- | --- | --- | --- |
| 划线高亮 | 微信读书/掌阅/番茄/多看/Android Legado ✅ | ❌ | 无任何高亮数据模型 |
| 笔记 / 批注 / 想法 | 微信读书（核心）/番茄/Android Legado ✅ | ❌ | 只有"书签=位置"，不能写内容 |
| 笔记管理页 + 导出 | 微信读书（可导出）/多看 ✅ | ❌ | — |
| 书摘卡片生成 / 分享图 | 微信读书/掌阅 ✅ | ❌ | 只有"分享书籍链接" |
| 全书搜索 | 微信读书/多看/Android Legado ✅ | 🟡 仅本章 | `contentSearchResults` 只过滤当前章 `model.paragraphs` |
| 全库搜索（跨书） | 多看/Android Legado ✅ | ❌ | 无 FTS 索引 |
| 词典 / 查词 / 生词本 | 多看/掌阅/微信读书 ✅ | ❌ | — |
| 翻译（整段/整章） | 微信读书/掌阅 ✅ | ❌ | — |
| 简繁转换 | 多看 ✅ | ❌ | — |
| 拼音 / 注音 | 七猫（拼音阅读）✅ | ❌ | — |
| 段评 / 章评 / 弹幕 | 番茄/七猫/起点 ✅ | ❌ | 与"无社区"定位有关，可延后 |
| 角色表 / 人物关系 | 微信读书 AI/番茄 ✅ | ❌ | — |
| AI 问书 / 大纲 / 速读 / 总结 | 微信读书（AI 问书、AI 大纲）、掌阅（AI 速读）✅ | ❌ | 2025 年横评里已被列为"标配级"卖点 |

### B. 听书（TTS / 有声）

| 能力 | 标杆 | 本项目 | 说明 |
| --- | --- | --- | --- |
| 系统 TTS 朗读 | 全部 ✅ | ✅ | — |
| 自定义 HTTP TTS 引擎 | Android Legado ✅ | ✅ | `HttpTTSManagementView` 支持 Header/JS/登录脚本，做得比多数商业 App 更开放 |
| 多音色 / 情感音色 | 微信读书（真人有声 + AI 听书）、番茄畅听 ✅ | 🟡 仅系统音色 + 引擎音色 | 无角色音色、无情感切换 |
| 方言音色 | 番茄畅听/七猫（部分）✅ | ❌ | — |
| 定时关闭 | 七猫/番茄 ✅ | ✅（剩余分钟提示） | — |
| 听书字幕联动 | 番茄畅听 ✅ | 🟡 有按页朗读定位 | 无逐句卡拉 OK 式高亮 |
| 真人有声书 | 微信读书 ✅ | ❌ | 需版权内容，与"不提供内容"定位冲突，可不做 |

### C. 统计 / 激励

| 能力 | 标杆 | 本项目 | 说明 |
| --- | --- | --- | --- |
| 今日/累计/连续天数 | 全部 ✅ | ✅ | — |
| 单书阅读时长 | 微信读书/番茄 ✅ | ❌ | 统计只有全局维度 |
| 阅读速度（字/分钟） | 微信读书 ✅ | ❌ | — |
| 月度 / 年度报告 | 微信读书 ✅ | ❌ | — |
| 时段分布 / 热力图 | 微信读书 ✅ | ❌ | — |
| 阅读目标 / 打卡 | 微信读书/番茄 ✅ | ❌ | — |
| 成就 / 勋章 / 等级 | 番茄/七猫 ✅ | ❌ | 可做轻量版（纯本地） |

### D. 书籍管理

| 能力 | 标杆 | 本项目 | 说明 |
| --- | --- | --- | --- |
| 分组 | 全部 ✅ | ✅ | — |
| 标签 / 自定义分类标签 | 多看/微信读书 ✅ | 🟡 只有分组 | 无多标签 |
| 阅读状态（想读/在读/已读/弃读） | 微信读书 ✅ | ❌ | — |
| 评分 / 短评 | 微信读书/番茄 ✅ | ❌ | — |
| 书单 / 合集 | 微信读书/多看 ✅ | ❌ | — |
| 批量操作（批量缓存/更新/导出/移动） | Android Legado ✅ | 🟡 仅批量删除书源、批量归组 | 书架侧缺批量 |
| 书籍详情页信息（评分/同类推荐/字数/状态） | 全部 ✅ | 🟡 仅简介 + 目录 | `BookDetailView` 信息较单薄 |
| 本地书全文索引与重命名规则 | 多看 ✅ | 🟡 有重命名，无索引 | — |

### E. 数据安全与迁移（**最痛**）

| 能力 | 标杆 | 本项目 | 说明 |
| --- | --- | --- | --- |
| 一键备份（书源+规则+设置+书架+进度+书签+统计） | Android Legado ✅ | ❌ | 只能手动导出单类规则 JSON |
| 备份加密 / 定时备份 / 保留份数 | Android Legado ✅ | ❌ | — |
| 一键恢复 / 覆盖或合并 | Android Legado ✅ | ❌ | — |
| 导入 Android Legado 备份包 | Android Legado ✅（.zip） | ❌ | iOS 用户迁移的最大门槛 |
| 跨设备同步范围 | Android Legado（WebDAV 全量）✅ | 🟡 仅书架/分组/进度/本地书原文件 | 文档明确不同步：书源、登录态、Cookie、书签、统计、缓存 |
| EPUB / 笔记导出 | 多看/微信读书 ✅ | 🟡 仅缓存正文导出 TXT | 无 EPUB 导出、无笔记导出 |
| 崩溃上报 | 商业 App ✅ | 🟡 仅本地日志 + 手动导出 | 无远程收集，符合隐私定位 |

### F. 平台与系统集成

| 能力 | 标杆 | 本项目 | 说明 |
| --- | --- | --- | --- |
| 主屏/锁屏小组件（在读、今日时长） | 微信读书/番茄 ✅ | ❌ | 未引入 WidgetKit |
| 实况活动（朗读/自动阅读进度） | 部分 App ✅ | ❌ | — |
| Siri / 快捷指令 / App Intents | 微信读书（部分）✅ | ❌ | — |
| 聚焦搜索（Spotlight） | 多看 ✅ | ❌ | — |
| iPad 分栏 / 横屏双栏 | 微信读书/掌阅 ✅ | ❌ | 无 `NavigationSplitView`，iPad 上应是放大版 iPhone 布局 |
| iCloud / CloudKit 同步 | 多看/微信读书 ✅ | ❌ | 目前只支持自建 WebDAV/S3/Dropbox，配置门槛高 |
| 系统分享接收（浏览器/微信 → 加入书架） | 多看/微信读书 ✅ | ❌ | 无 Share Extension |
| 章节更新通知 / 角标 | 番茄/七猫 ✅ | ❌ | 完全没有通知能力 |
| 多语言界面 | 商业 App ✅ | ❌ | 仅简体中文 |
| Handoff / 接力 | 多看 ✅ | ❌ | — |

---

## 四、优先级与实现要点

### P0 —— 补"阅读器该有但没有"的硬缺口

**P0-1 划线高亮 + 笔记 + 导出**
- 数据层：新增 `BookNoteRepository`（SQLite，`LegadoDatabase` 已有连接与迁移机制），表 `book_note(book_url, chapter_index, start_offset, end_offset, selected_text, note_text, color, created_at, updated_at)`，与 `BookChapterRepository` 同库同事务管理。
- 渲染层：`ReaderTextView` 基于 `UITextView`，已有 `selectedRange`；UIKit 的 `NSLayoutManager` 不提供 AppKit 临时属性接口，实际通过子类重写背景绘制来高亮，避免重建 attributed string 影响分页。
- 菜单：`UIEditMenuInteraction` 自定义"高亮 / 写想法 / 复制 / 搜索 / 分享"。
- 管理页：仿 `AllBookmarksView` 做"本书笔记"，支持按书/按时间筛选；导出 Markdown（含书名、章节、原文、想法、时间）。
- EPUB：Readium 有 locator 体系，按 locator + 文本偏移存同样的 note 表，双端共用。

**P0-2 一键备份 / 恢复（含 Android Legado 备份导入）**
- 打包：`ZIPFoundation` 已在依赖里。备份内容 = 书源 JSON + 替换规则 + TXT 目录规则 + RSS 源 + TTS 配置 + 书架/分组/进度/书签/统计 SQLite 导出 + `ApplicationSettings`。
- 通道：复用 `Remote/RemoteStorage.swift`（WebDAV/S3/Dropbox）与本地"文件"导出；可选 AES 加密（CryptoKit 已链接）。
- 恢复：先落临时目录做结构校验，再事务性写入；失败整包回滚（现有 `BookLibraryModel.persist` 的失败回滚模式可参照）。
- Android Legado 兼容：识别其备份 zip 目录结构（`bookshelf`/`bookSource`/`replaceRule`/`readRecord` 等 JSON），做字段映射层 `LegadoBackupImporter`，未知字段保留透传。

**P0-3 全书 / 全库搜索**
- 在 `LegadoDatabase` 建 FTS5 虚表（`sqlite3` 已链接）：`chapter_fts(chapter_id, book_url, title, content)`，写入时机跟 `ChapterContentCache` 落盘一致。
- UI：阅读器把"搜索本章"改为"本章 / 全书"分段控件；书架加"全库搜索"入口，结果按书聚合，点击直达章节位置。

**P0-4 同步范围扩展**
- 现有 `BookshelfSync` 已有"每设备不可变快照 + 合并"骨架，扩展为多命名空间：`LegadoSync/v1/books`、`/sources`、`/rules`、`/bookmarks`、`/stats`。
- 冲突策略沿用现有"时间 + 事件序号 + 设备标识"决胜；书源/规则按 `bookSourceUrl` / `ruleId` 为键做 LWW 合并，删除用墓碑记录（现有删除传播机制可复用）。

**P0-5 章节更新通知**
- `UNUserNotificationCenter` 本地通知：书架后台刷新（现有 `BookUpdateCoordinator`）发现新章节时投递；设置页加"更新提醒"开关与免打扰时段；角标数 = 待读更新章节数。

### P1 —— 对标主流体验

| 项 | 要点 |
| --- | --- |
| 书摘卡片 | `ImageRenderer` 生成 2:3 分享图（背景取当前阅读主题、可选字体），零后端成本 |
| 词典 / 翻译 | 先用系统 `UIReferenceLibraryViewController`（离线、免权限）做"查词"；翻译走用户自配 API（与 HTTP TTS 同样的"用户自带配置"模式） |
| 简繁转换 | 内置 OpenCC 精简映射表（常用字表即可，约 3k 条），在 `ContentSanitizer` 之后、分页之前做一遍 |
| 阅读目标 / 打卡 | `ReadingActivityRepository` 已有日粒度时长，加 `daily_goal_minutes` + 连续达成记录，纯本地 |
| 统计深化 | 单书时长（按 `book_url` 聚合现有 activity 表）、阅读速度（字数/分钟，`ReaderViewModel` 有段落字数）、月报页 |
| 批量操作 | 书架多选：批量缓存、批量更新、批量归组、批量导出 |
| 书籍详情增强 | 评分/字数/状态本地字段 + "同作者其他书"（用现有搜索能力拉取） |
| Widget | `WidgetKit` + App Group 共享一份 `UserDefaults` 快照（在读书名、进度、今日时长、待更新数），避免 widget 直连 SQLite |
| iPad 适配 | `NavigationSplitView`：侧栏书籍/分组，右侧阅读器；`horizontalSizeClass == .regular` 时阅读器双栏 |

### P2 —— 差异化（AI 与多形态）

| 项 | 要点 |
| --- | --- |
| AI 问书 / 大纲 / 总结 | 不内置内容、只做"对当前章节/全书正文"的推理：用户自配 OpenAI 兼容 endpoint + Key（存 Keychain），功能入口在阅读菜单；大纲结果缓存到本地，避免重复消耗 |
| TTS 多音色 / 方言 | HTTP TTS 引擎层已支持参数化，加 `voice` / `emotion` / `dialect` 三个可选字段即可；对系统 TTS 暴露 `AVSpeechSynthesisVoice` 全量列表（现在只有中文默认声） |
| 漫画 / 图片书 / PDF | 新 Reader 类型：CBZ 走 ZIPFoundation 解包 + 横向翻页；PDF 走 PDFKit（系统框架） |
| 实况活动 | 朗读/自动阅读时用 `ActivityKit` 显示进度与暂停按钮 |
| App Intents | "继续阅读""搜索书名""今日时长"三个 intent，顺带打通 Siri 与快捷指令 |
| Share Extension | 接收 URL → 走现有 `AddBookURLService` 直接加入书架 |

### P3 —— 谨慎评估

- 多语言界面（成本高、收益依赖用户结构）
- 社区 / 段评 / 书荒广场（与"不提供内容、不做运营"的定位冲突，且需服务端）
- 会员 / 广告 / 金币体系（**不建议**，与项目定位和合规姿态直接冲突）

---

## 五、建议的取舍

**该抄的**：笔记链路、备份恢复、全书搜索、通知、Widget、iPad 分栏 —— 这些是"阅读器基本功"，缺了就是半成品。

**该超的**：书源兼容度、搜书并发速度、HTTP TTS 开放度、EPUB 原排版、远端存储自由度 —— 这五项已经领先商业 App（商业 App 不可能让你自带书源和 TTS 引擎），是真正的护城河，值得继续加码（例如书源调试器加"差异对比/规则热更新预览"）。

**不该抄的**：广告、金币提现、会员墙、短剧、社区广场。它们解决的是"平台变现"，本项目解决的是"个人阅读工具"，抄过来只会稀释体验并带来合规风险。

---

## 六、验证方式（建议随功能一起落）

- 备份/恢复：`LegadoCoreTests` 加"导出 → 清库 → 导入 → 全量 diff"往返测试，覆盖空书架、含本地书、含 Keychain 凭据、含损坏 zip 四类用例。
- 笔记：offset 在换字号/换字体/换主题后仍能定位（用不同 `fontSize` 跑同一批 note 做断言）。
- 全书搜索：10 万段落量级的 FTS5 建索引与查询耗时基线。
- 通知：模拟器 `simctl push` + 真机免打扰时段。
- Widget：App Group 快照与主 App 数据一致性断言。

---

*本文档为功能规划参考，具体排期需结合实际维护节奏。*
