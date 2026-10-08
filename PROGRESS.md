# WikiReader 进度与决策记录

> 记录 SPEC.md 之外、在开发对话中确定的事：各阶段状态、代码地图、做过的决定和原因、验证状态、待办。
> 需求本身以 SPEC.md 为准；代码细节看 git log（每个提交说明都写了原因）。
> 上一个长会话（2026-10-07 至 10-08）的完整过程记录在 `docs/SESSION-2026-10-07-08.md`（不是自动加载的，需要时读）。

## 0. 接手须知（新会话先读这里）

**一句话现状**：阶段 0–5 的核心功能都做完了（抓取清洗、阅读、点词查词典、系统/OpenAI 朗读、文章库、设置），10-07/08 又加了：App 图标、词典界面的发音按钮和 AI 讲解按钮、Voice 合并页、沉浸式阅读页（上下边缘菜单、排版面板、多选翻译、段末翻译）。201 个单元测试全过。**但阅读页的触摸操作和词典上的浮动按钮从来没有人点过，真机上也还没装最近几版。**

**先做这几件事**
1. `git pull`，按 CLAUDE.md 编译并跑测试（见第 6 节的环境注意事项）。
2. 把最新版装到真机或模拟器，**把第 4 节里标"未验证"的项逐个点一遍**。上次出的事就在这里（顶部菜单点不出来、没法返回）。
3. 有问题优先修；没有再问用户下一步做什么。第 5 节列了待办和待用户决定的事。

**不要重复做的事**
- "Search Web" 去不掉（系统词典自己画的）。用户已决定保留，不要再提。
- 点词先弹词卡 + 自动发音的做法被用户否决过（要的是：直接弹系统词典，按喇叭才发音）。
- OpenAI 的 Vibe/Style 预设用户说先不加。

**协作偏好**见 CLAUDE.md "协作偏好"一节（中文交流、别每个细节都问、界面先自己截图看、长时间干活别沉默、说清哪些没验证）。
**推送**：上一台开发机没有 GitHub 凭据，`git push` 一直由用户自己做，不要自作主张推；commit 随时可以做。

## 1. 阶段状态（截至 2026-10-08）

| 阶段 | 状态 | 备注 |
|---|---|---|
| 0 工程初始化 | ✅ 完成 | |
| 1 抓取、清洗、显示、保存 | ✅ 完成 | |
| 2 点词查词典 | ✅ 模拟器验收 | ⏳ 真机：系统词典、英汉释义 |
| 3 朗读（系统声音） | ✅ 模拟器验收 | ⏳ 真机：Premium 声音音质、高亮与声音同步 |
| 4 文章库与设置 | ✅ 完成 | 断网验收按决定未实测（日志确认打开/朗读无网络请求） |
| 5 OpenAI TTS | ✅ 模拟器验收 | 其余阶段 5 项（锁屏后台、分享导入、生词本）未开始；AI 释义已做第一版 |

测试：201 个单元测试（Swift Testing），在 iPhone 15 Pro Max 模拟器上全部通过。

## 2. 代码地图

**App/**：`WikiReaderApp`（入口、SwiftData 容器、启动时请求词形还原模型）、`Log`（os_log 的各个 logger，subsystem `tik.tian.com.WikiReader`）、`SettingsKeys`（所有 `@AppStorage` 的键，以及 `SpeechEngineChoice`）。

**Models/**：`Article`（SwiftData：标题、来源 URL、添加时间、内容块 JSON、上次读到的块序号）、`ContentBlock`（标题或段落）。

**Services/**
- 抓取与清洗：`ArticleInput`（链接/标题解析）、`WikipediaClient`（TextExtracts API，专用 URLSession，15/30 秒超时）、`ArticleCleaner`、`ArticleImporter`（输入 → 标题 → 抓取 → 清洗）。
- 朗读：`SpeechEngine`（协议）、`SystemSpeechEngine`、`ReadingSession`（朗读流程，`@Observable`）、`SpokenAudioSession`（音频会话）、`VoiceSelection`（声音排序/选择，含 `americanVoice`）、`VoiceChoice`（"当前用哪个声音 + 引擎"，设置页和主页那一行的文字）。
- 查词：`DictionaryLookup`（候选词顺序、词形还原、所在句子）、`WordPronouncer`（词典上喇叭按钮用的单词发音，固定美式）。
- 钥匙串：`KeychainStore`（OpenAI Key）。
- `OpenAI/`：
  - 朗读：`OpenAITTSClient`、`OpenAISpeechEngine`、`SpeechChunking`、`SpeechAudioCache`、`AudioClip`。
  - 聊天（讲解、翻译）：`OpenAIChatClient`（共用请求层：Structured Outputs、错误映射 `OpenAIChatError`、专用 URLSession）、`OpenAIExplainClient`（单词讲解 + `WordExplanation`）、`OpenAITranslateClient`（翻译 + `PassageTranslation`）、`TranslationCache`（磁盘缓存）。

**Views/**
- `Library/`：`LibraryView`（文章列表、左滑删除）、`AddArticleView`（添加文章 sheet）。
- `Reader/`：
  - `ReaderView`：阅读页容器——沉浸式（隐藏导航栏/状态栏）、顶/底菜单的显隐、各个 sheet（设置、排版、翻译）、查词和翻译的入口。
  - `ArticleTextView`：只负责 UIKit `UITextView` 的那一层——点词、选择菜单、点击区域（`TapZone`）、高亮、自动跟随滚动、位置恢复。
  - `ArticleDocument`：整篇文章的富文本 + "块 → 文本区间"映射；样式（`ReaderStyle`）、段末 "Translate" 标签、选中文字提取。
  - `ReaderStyle`：主题/字体/字号/行距/页边距/深色程度；`ReaderChrome`：`floatingGlass`、顶部菜单 `ReaderTopBar`、排版面板 `ReaderStylePanel`、`SwipeBackEnabler`；`PlayerBar`：底部播放胶囊；`SpeechErrorBanner`：朗读出错条。
  - `DictionaryPresenter`：弹系统词典；`PronouncingDictionaryViewController`（词典子类 + 喇叭 + AI 两个浮动按钮）。
  - `WordExplanationView`（单词 AI 讲解 sheet + `WordExplanationModel`）、`TranslationView`（翻译 sheet + `PassageTranslationModel`）。
  - `UITextView+WordHit`：点哪个词的命中判断。
- `Settings/`：`SettingsView`（主页：Voice 一行、默认语速、词典说明）、`VoiceSettingsView`（所有声音一页，单一对勾）。

**tools/make_icon.swift**：生成 App 图标的三张 PNG。**docs/**：会话记录。

**测试**（`WikiReaderTests/`）：每个服务和关键视图逻辑都有；`Fixtures/` 是 Wikipedia 的真实 API 返回样本（测试不联网）；`FakeSpeechEngine` 是朗读流程测试用的假引擎。

## 3. 关键决定（及原因）

### 阅读与查词
- 正文用一个 `UITextView`（阶段 1 就用，避免后面重写）；`ArticleDocument` 维护"块 → 全文区间"映射。**早期是只读、不可选择；2026-10-08 改成可选择**（为了多选翻译），单击仍是查词。
- 重复添加同一标题（含重定向后同名）时不新增，直接打开已有文章。
- 查词弹窗用 UIKit `present` 直接弹出 `UIReferenceLibraryViewController`，不用 SwiftUI sheet（避免两份"是否弹出"状态不同步）。
- 查词候选顺序：原词 → 去所有格 → 小写 → 词形还原（NLTagger，整段作上下文）。系统词典本身就认识多数变形词，所以词形还原只在原词查不到时起作用。

### 正文清洗（和 SPEC 预期不同的地方）
- Paris 首句如今本来就没有音标（维基百科挪到了脚注）；去音标规则应用到全文，靠"括号里有没有 IPA 字符"判断，保留 `"[the]"` 这类编辑方括号。
- 公式残留是一整串缩进行 + `{\displaystyle …}` 或 `{\textstyle …}`；整段删除。**行内公式删掉后句子会缺一块**（如 "a measure of and which contain"），暂未处理，可改成用 "a formula" 占位。
- 父章节在子章节都被删除后变空（如 "Notes and references"），一并删除。

### 朗读
- 朗读引擎抽象为 `SpeechEngine` 协议；`ReadingSession` 管流程，用假引擎做单元测试，另有真引擎冒烟测试。
- 每次交给引擎**整段文字 + 起始位置**（不是剩余文字），云端引擎才能在缓存音频里跳转，不重复付费。
- 暂停用 `pauseSpeaking(at: .immediate)`：`.word` 会在暂停请求到达前跨进下一个词，继续时重读该词。
- 切换语速时从**当前词开头**重读（用户确认保留这个行为）。
- 自动跟随滚动：用户手动滚动后暂停跟随，**停手 3 秒或读到下一段**时恢复；恢复时不立即拉回，等下一个词再滚。
- 系统声音选择：质量优先，同质量下现代声音（`com.apple.voice.*`）优先于老一代 MacinTalk/Eloquence（否则模拟器里会选中 "Fred"），再按口音、名字。
- 语速 4 档（0.75/1/1.25/1.5×），播放条和设置页的默认语速是**同一个值**。
- 未朗读时手动滚动会更新阅读位置；朗读或暂停中不会。离开阅读页时主动保存 SwiftData。
- 点词、打开翻译面板都会暂停朗读，关掉后保持暂停，按播放继续。

### OpenAI TTS（阶段 5）
- 模型 `gpt-4o-mini-tts`，默认声音 `marin`；风格说明（instructions）固定为 "Read like a clear, natural audiobook narrator, at a steady, moderate pace."，设置里没有入口（用户说先不加；如加，缓存键含 instructions，换风格会重新生成并重新计费）。
- 逐词高亮为**估算**（按词长和标点停顿分配时间），可能差一两个词。
- 语速用播放器速率实现，不重新生成；只预生成"当前段 + 下一段"；停止时不取消生成（已付费，存进缓存）。
- 音频缓存在 Application Support/SpeechAudio（不放 Caches，避免被系统清理后离线不可听）；删除文章不会删除缓存，只能在设置页手动清空。
- API Key 存 Keychain（本机、不同步）；代码和日志从不记录 Key。
- 出错时暂停并显示提示卡片：Key 问题给"Open Settings"（直接打开 Voice 页），其他给"Retry"，云端出错时都可"Use iPhone Voice"（仅本次）。从设置页返回会按新设置重建引擎并自动继续。

### 设置页（2026-10-08）
- 去掉 "Read With" 切换。设置主页只有一行 "Voice"（显示如 "Marin · OpenAI"），点进 Voice 页：OpenAI 分组（Key、13 个声音、缓存、删除 Key）在上，iPhone 声音在下，整页只有一个对勾，选哪个声音就用哪个引擎（`VoiceChoice`）。
- 没有 Key 时 OpenAI 声音带锁、不可选；删除 Key 时若正在用 OpenAI 声音，自动改回 iPhone 声音。存储的设置项（`speechEngine`、`voiceIdentifier`、`openAIVoice`）不变，不用迁移。

### 词典界面：发音与 AI 讲解（2026-10-08）
- 系统词典的内容改不了：不能加按钮，也不能去掉 "Search Web" / "Manage Dictionaries"。所以做成它的子类，在右下角叠两个浮动按钮：`✨ AI` 和喇叭。
- 点词直接弹词典，**不自动发音**；按喇叭才读被查的词，固定美式（en-US）本机声音（设置里选的声音是美式就用它，否则用最好的美式声音）。读单词不 `deactivate` 音频会话，避免影响暂停中的文章朗读。
- AI 讲解：点 AI 才请求 OpenAI，只发单词和所在句子，用设置页保存的同一个 Key。返回词性、中文释义、用法说明、整句翻译、3 个中英例句。无 Key、超时、限流、额度用完都有明确提示。**未做缓存**：重复点同一个词会重复请求（单次约千分之几美分）。
- 联网规则已写进 CLAUDE.md："AI 讲解/翻译只在点按钮时请求，只发单词/所选文字"。
- 抓取 Wikipedia 改用专门的会话：15 秒无响应、总共 30 秒就报"超时"（原来 `URLSession.shared` 默认 60 秒/7 天，网络差时像无限转圈）。

### 阅读页改版（2026-10-08）
- **沉浸式**：默认隐藏状态栏、导航栏、播放条。点屏幕最上方（含灵动岛那条安全区，用一个看不见的 SwiftUI 点击条 `topTapStrip` 覆盖）出顶部菜单；点最下方出播放条；中间点词仍查词，同时收起菜单；开始滚动也收起。朗读出错时错误条始终显示。文本视图只在底部忽略安全区（顶部留出灵动岛，第一行不会被挡）。隐藏导航栏会关掉左边缘滑动返回，用 `SwipeBackEnabler` 重新打开（**未验证**）。
- **（2026-10-08 晚，取代下面的"菜单样式"和"排版面板"）** 菜单改成整条页面底色的栏，不再悬浮、不用玻璃：顶部菜单 `ReaderTopMenu` 直接放排版设置（字号滑块、主题、字体、行距、页边距、恢复默认），没有标题和返回箭头，返回靠左边缘右滑；底部是整条播放栏（左速度、中间上一段/播放/下一段）。排版 sheet 已删除。
- **菜单样式（旧）**：顶部三个悬浮件（返回圆钮、标题胶囊、`AA` 圆钮），底部一个悬浮胶囊（语速、上一段、播放/暂停、下一段）。iOS 26+ 用 Liquid Glass；**玻璃后面必须垫一层页面色**（否则玻璃会把后面的文字折射成噪点）；再加细边线和阴影，浅色页面上才看得出是浮起来的；旧系统用材质。菜单自己吃掉点击（`.onTapGesture {}`），免得点到文字上又把菜单收了。
- **排版面板**（`ReaderStyle`）：卡片式。主题（Auto/Light/Sepia/Dark）、5 种字体（卡片里用该字体显示 "Aa"）、字号 14–32、行距 3 档、页边距 3 档，存 `@AppStorage`，改动实时生效，面板打开时背后的文章仍可见。深色主题是柔和炭灰（原近黑 #171717 太刺眼），选中深色时多一个 Soft–Deep 滑块；滑块只改页面色，不重建文章。改样式会重建整篇文字，文本视图按"当前顶部的块"恢复位置。
- **多选翻译**：长按选词、拖手柄可跨段。选择菜单自己做（AI Translate / Read From Here / Copy），不用系统菜单（系统的 Look Up / Share 会带出网络搜索）。**原来的"长按某段开始朗读"改成了选择菜单里的 Read From Here**（SPEC F5 已同步）。
- **段末翻译**：每个段落（不含标题）末尾追加小号蓝色 "Translate"，是段落富文本的一部分但**不在块范围内**（`translateBlock` 属性；不参与朗读、高亮、取词、选中文字）。点它和多选翻译共用同一个翻译面板；没做成段落下方内联展开（要改整篇布局，风险大）。
- 翻译走 `OpenAIChatClient`，结果按（模型 + 原文）缓存到 Application Support/Translations，同一段再看不重复请求，离线也能看缓存。上限 6000 字符，超出只翻前面并提示。

### 单词本（2026-10-08 晚）
- 每篇文章自己一份单词本：`Article.savedWordsData`（JSON，和 blocks 一样存成一个字段，带默认值，旧数据库原地升级）；`SavedWord`（单词、查询词、所在句子、时间），同一个查询词（不分大小写）只算一条。
- 收藏入口：系统词典右下角的书签按钮（和 AI、喇叭一排），已收藏时是实心，再点取消。
- 查看入口：阅读页在正文上**向左滑**（明显横向、距离超过 80pt 才触发，不影响上下滚动），Saved Words 面板**从右边滑进来并占满全屏**（原来的底部 sheet 已换掉；`ReaderView.savedWordsPanel`），点 ✕ 或在面板上向右滑收回；面板打开时系统的左边缘右滑返回被关掉（`SwipeBackEnabler(isEnabled:)`），免得一滑把整篇文章退出去；点一行打开该词的词典，左滑一行删除。**滑动手势和面板里点词都没法在模拟器自动化，未验证。** 没有可见的按钮入口（只有手势）。
- 正文里收藏过的词（原词或查询词，不分大小写、带 `'s` 也算，整词匹配）用淡橙色底标出；朗读高亮、点词闪烁盖在它上面，结束后恢复淡橙色。收藏/取消后下次回到阅读页重算（`ArticleDocument.ranges(ofWords:)`，只在收藏集变化或文章重建时算）。只标正文块，不标文章大标题。截图验证过浅色主题；深色主题的颜色没看。
- 列表只显示单词和中文释义，不再显示所在句子（句子仍存着，给 AI 用）。**系统词典的释义文字 App 读不出来**，所以释义来自 AI：在词典里点过 ✨AI 的词，收藏时/之后自动带上释义；没有释义的行有 "Meaning" 按钮，点了才请求 OpenAI（不改联网规则：只在点按钮时、只发单词和句子）。用户没指定来源，这是我的默认选择；若想收藏时自动请求，要先改 CLAUDE.md 联网规则。
- 左滑手势加了 `allowedScrollTypesMask = .all`，让模拟器触控板双指滑动也能触发（原来只有按住鼠标拖才行）。**未验证**。
- 15 个单元测试（`SavedWordTests`、`SavedWordHighlightTests`、`SavedWordMeaningTests`）。

### 其他
- 模拟器默认用 iPhone 15 Pro Max（和另一个项目共用）。App 图标：蓝色渐变底 + 白色书本 + 声波，浅色、深色、着色三个版本，由 `tools/make_icon.swift` 生成。

## 4. 验证状态

| 内容 | 状态 |
|---|---|
| 单元测试（201 个） | 15 Pro Max 模拟器全过 |
| 沉浸式布局、顶/底菜单样式、排版面板、翻译面板显示 | 截图验证过（浅色、沙色、深色） |
| 翻译请求 | 模拟器里用真实 Key 成功过一次（`gpt-4o-mini` 可用） |
| 点屏幕最上/最下出菜单、顶部点击条 | **未验证** |
| 左边缘滑动返回 | **未验证** |
| 长按选择、选择菜单、Read From Here | **未验证** |
| 段末 "Translate" 的点击命中 | **未验证** |
| 词典右下角喇叭 + AI 按钮：位置、是否挡内容、能否点到 | **从未见过**（只能真机） |
| 美式发音效果、AI 讲解内容质量 | **未验证** |
| 真机上的最新版（超时、Voice 页、AI 按钮、沉浸式阅读页、新菜单） | **没装**（手机一直是 unavailable：锁屏或未连线） |
| 阶段 2/3 真机项：系统词典英汉释义、Premium 声音音质、高亮同步 | 仍待真机 |

## 5. 待办与想法

**待用户决定**
- [ ] **OpenAI 限流自动重试**：新账号/低等级账号容易遇到 429（首次试听连续 3 次被限流）。建议：仅对限流重试，按 `Retry-After` 或 1/2/4 秒，最多 3 次。
- [ ] 单词讲解要不要缓存（现在每次点都请求）。
- [ ] OpenAI 的 Style（Vibe）预设：用户说先不加。
- [ ] 联网词典取真人录音/音标：要改 CLAUDE.md 的联网规定，用户没要求。
- [ ] 段落翻译是否改成段落下方内联展开（现在是 sheet）。

**已知问题**
- [ ] 行内公式删除后句子缺词（见上）。

**阶段 5 其余**
- [ ] 锁屏/后台朗读、Share Extension、生词本（可把 AI 讲解存进生词本）。

## 6. 开发环境注意事项

- **在仓库根目录启动 Claude Code**，CLAUDE.md 才会自动加载。
- 跑测试要带 `-parallel-testing-enabled NO -collect-test-diagnostics never`（见 CLAUDE.md），否则测试失败时 xcodebuild 会"卡"10 分钟收集诊断，并行测试还会克隆、关掉共用的模拟器。
- 共用的 iPhone 15 Pro Max 模拟器上，NLTagger 的 `.lemma` 模型要下载，没下好时 8 个依赖词形还原的测试会失败（重装 App 会让模型重置）；等模型下好就过，iPhone 17 模拟器上稳定。iPhone 17 上 `SystemSpeechEngineTests`（真合成器冒烟测试）会 60 秒超时，和代码无关。
- 测试是宿主测试（跑在 App 进程里）：会写磁盘缓存的测试要用临时目录，不要碰 `.standard`。日志里的 `[AXCommon] unsafeForcedSync` 是无害噪音。
- 没有模拟器点击自动化。要看某个界面：临时加启动参数（例如 `-debugOpenFirst` 自动打开第一篇文章，`-debugTop` 直接显示顶部菜单），`xcrun simctl launch <设备> tik.tian.com.WikiReader -debugOpenFirst`，**至少等 8 秒**（冷启动慢），再 `xcrun simctl io <设备> screenshot x.png`。看完**必须删掉临时代码，不要提交**。如果临时开关写进了 `@AppStorage`（主题等），要用 `xcrun simctl spawn <设备> defaults delete tik.tian.com.WikiReader <key>` 清掉。
- 通过 `os_log`（subsystem `tik.tian.com.WikiReader`）和 SwiftData 数据库核对行为；各功能关键事件都有日志。
- 模拟器的钥匙串里可能有 OpenAI Key：调试时翻译/讲解是真请求（费用极小）。**换电脑后要在设置页重新输入 Key。**
- Mac 常用 iPhone 热点；热点开了"低数据模式"时，系统的大文件下载（模拟器运行时等）会停住不动。
- 真机运行需在 Xcode 里配置签名（Personal Team，免费账号 7 天后需重新安装）。命令行装真机：`xcodebuild -scheme WikiReader -destination 'id=<手机 UDID>' -derivedDataPath <目录> -allowProvisioningUpdates DEVELOPMENT_TEAM=<团队 ID> build`，再 `xcrun devicectl device install app --device <UDID> <.app 路径>` 和 `xcrun devicectl device process launch --device <UDID> tik.tian.com.WikiReader`。手机必须解锁并连线（`xcrun devicectl list devices` 里状态是 connected）。首次需在手机「设置 → 通用 → VPN 与设备管理」里信任开发者。团队 ID 不在工程里，要命令行传（Xcode 的 Signing 页能看到，或问用户）。
- 编辑含中文的文档时，`python3` 要用 `-X utf8` 并显式 `encoding='utf-8'`。
- Swift 并发写法见 `docs/SESSION-2026-10-07-08.md` 第 3 节（`@concurrent`、typed throws、`Task` 里的 catch、`[String: Any]` 不能做 `static let`）。
