# WikiReader 进度与决策记录

> 记录 SPEC.md 之外、在开发对话中确定的事：各阶段状态、代码地图、做过的决定和原因、验证状态、待办。
> 需求本身以 SPEC.md 为准；代码细节看 git log（每个提交说明都写了原因）。
> 上一个长会话（2026-10-07 至 10-08）的完整过程记录在 `docs/SESSION-2026-10-07-08.md`（不是自动加载的，需要时读）。

## 0. 接手须知（新会话先读这里）

**一句话现状**：阶段 0–5 的核心功能都做完了（抓取清洗、阅读、点词查词典、系统/OpenAI 朗读、文章库、设置），10-07/08 又加了：App 图标、词典界面的发音按钮和 AI 讲解按钮、Voice 合并页、沉浸式阅读页（上下边缘菜单、排版面板、多选翻译、段末翻译）。411 个单元测试全过。10-13 又换成了自己的词典页（离线 ECDICT + 在线 Wiktionary + 真人发音）、改成解析 HTML 抓文章、加了播放日志和 OpenAI 声音响度。**但阅读页的触摸操作和词典页上的按钮我这边都没法点，真机上的表现要用户验证。**

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

## 1. 阶段状态（截至 2026-10-09）

| 阶段 | 状态 | 备注 |
|---|---|---|
| 0 工程初始化 | ✅ 完成 | |
| 1 抓取、清洗、显示、保存 | ✅ 完成 | |
| 2 点词查词典 | ✅ 模拟器验收 | ⏳ 真机：系统词典、英汉释义 |
| 3 朗读（系统声音） | ✅ 模拟器验收 | ⏳ 真机：Premium 声音音质、高亮与声音同步 |
| 4 文章库与设置 | ✅ 完成 | 断网验收按决定未实测（日志确认打开/朗读无网络请求） |
| 5 OpenAI TTS | ✅ 模拟器验收 | 其余阶段 5 项（锁屏后台、分享导入、生词本）未开始；AI 释义已做第一版 |

测试：411 个单元测试（Swift Testing），在 iPhone 15 Pro Max 模拟器上全部通过。

## 2. 代码地图

**App/**：`WikiReaderApp`（入口、SwiftData 容器、启动时请求词形还原模型）、`Log`（os_log 的各个 logger，subsystem `tik.tian.com.WikiReader`）、`SettingsKeys`（所有 `@AppStorage` 的键，以及 `SpeechEngineChoice`）。

**Models/**：`Article`（SwiftData：标题、来源 URL、添加时间、内容块 JSON、上次读到的块序号）、`ContentBlock`（标题或段落）。

**Services/**
- 抓取与清洗：`ArticleInput`（链接/标题解析）、`WikipediaClient`（`action=parse` 取 HTML，专用 URLSession，15/30 秒超时）、`ArticleHTMLParser`（HTML → 标题/段落，白名单）、`ArticleCleaner`（章节排除、去音标、引用标记兜底、标点整理）、`ArticleImporter`（输入 → 标题 → 抓取 → 清洗）。
- 朗读：`SpeechEngine`（协议）、`SystemSpeechEngine`、`ReadingSession`（朗读流程，`@Observable`）、`SpokenAudioSession`（音频会话）、`VoiceSelection`（声音排序/选择，含 `americanVoice`）、`VoiceChoice`（"当前用哪个声音 + 引擎"，设置页和主页那一行的文字）。
- 查词：`DictionaryLookup`（候选词顺序、词形还原、所在句子）、`WordPronouncer`（喇叭：先真人录音，没有就系统美式声音）。`Dictionary/`：`DictionaryDatabase`、`DictionaryEntry`（离线词库）、`WiktionaryClient` + `DefinitionCache`、`WordAudioClient`。
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
  - `DictionaryPresenter`：弹词典页；`WordCardView`/`WordCardModel`：自己的词典页（离线 ECDICT + 在线 Wiktionary + 真人发音）。
  - `WordExplanationView`（单词 AI 讲解 sheet + `WordExplanationModel`）、`TranslationView`（翻译 sheet + `PassageTranslationModel`）。
  - `UITextView+WordHit`：点哪个词的命中判断。
- `Settings/`：`SettingsView`（主页：Appearance、Voice 一行、词典说明、Backup & Transfer 入口）、`VoiceSettingsView`（所有声音一页，单一对勾）。

**tools/make_icon.swift**：生成 App 图标的三张 PNG。**docs/**：会话记录。

**测试**（`WikiReaderTests/`）：每个服务和关键视图逻辑都有；`Fixtures/` 是 Wikipedia 的真实 API 返回样本（测试不联网）；`FakeSpeechEngine` 是朗读流程测试用的假引擎。

## 3. 关键决定（及原因）

### 阅读与查词
- 正文用一个 `UITextView`（阶段 1 就用，避免后面重写）；`ArticleDocument` 维护"块 → 全文区间"映射。**早期是只读、不可选择；2026-10-08 改成可选择**（为了多选翻译），单击仍是查词。
- 重复添加同一标题（含重定向后同名）时不新增，直接打开已有文章。
- 查词弹窗用 UIKit `present` 直接弹出 `UIReferenceLibraryViewController`，不用 SwiftUI sheet（避免两份"是否弹出"状态不同步）。
- 查词候选顺序：原词 → 去所有格 → 小写 → 词形还原（NLTagger，整段作上下文）。系统词典本身就认识多数变形词，所以词形还原只在原词查不到时起作用。

### 正文清洗（2026-10-13 改成解析 HTML）
- **起因**：用户发现 Cultural Revolution 里一段没显示。原因是 TextExtracts 默认**删掉页面里所有 `div` 里的内容**，而 Wikipedia 用模板把别的词条的段落/小节"摘录"（`div.excerpt-block`）嵌进来，整段就丢了。COVID-19 丢了 24 段、约 12,800 字符（18%）；抽样的 16 篇长文里 3 篇有这类问题。
- **现在**：`WikipediaClient` 用 `action=parse` 取 HTML（压缩后 200–300 KB，抓一篇约 2–3 秒），`ArticleHTMLParser` 自己写的容错分词器（`XMLParser` 读不了，这不是合法 XML）按**白名单**取 `p/li/dd/dt/h2–h6`，其余整块跳过：表格、信息框、导航框、`figure`/图片说明、引语框（`blockquote`、`quotebox`、`templatequote`、署名 `templatequotecite`）、`hatnote`（含 "This paragraph is an excerpt from"）、脚注上标、`noprint/nomobile/noexcerpt`、`display:none`（含坐标的十进制隐藏部分）、公式、书目条目（`cite.citation`）、分栏长列表（`div-col`、`columns`）。块级公式（`mwe-math-element-block`）在段内断开成两段，和以前一致。**用户明确要求：图片说明、引语框、"Main article" 提示行都不读也不显示。**
- 保留的老规则：章节排除（整个子树）、空章节删除、去 IPA/listen、`[1]`/`[citation needed]` 兜底、标点整理；公式整段/整句删除（行内公式删掉后句子会缺一块，仍是已知问题）。
- 新旧对比（16 篇真实文章，旧版输出 vs 新版输出）：大多数段落逐字相同（例如 Einstein 218 段里 207 段相同）；不同的主要是旧版在页面里的 div 处把一个段落**拆成了两段**，新版保持完整；新增的主要是摘录段。残留扫描（引用标记、`[edit]`、公式、网址、署名行、过短块）0 条。
- **不影响已有数据**：已保存的文章存的是清洗好的块，备份导出/导入用的也是库里已存的块；OpenAI 音频缓存文件名 = SHA256(模型+声音+风格+段落文字)，所以**旧文章、旧备份、已下载的语音都不受影响**。只有以后新添加的文章走新解析。**注意**：以后若做"刷新旧文章"，没变的段落必须逐字一致才能继续命中旧语音缓存；被旧版拆开又被新版合并的段落会失效（要重新生成）。
- **已保存的旧文章不会自动补上摘录**：重复添加同一标题会直接打开旧文章，所以要补全得先删掉再添加（或以后加"刷新"入口，要处理阅读位置、单词本）。
- 测试 fixture 现在是 `action=parse` 的真实返回（Einstein/Paris/Pythagorean 各约 0.5–1 MB）+ 一份从 Cultural Revolution 截出来的摘录小节（`excerpt_section.json`）。
- 其他旧说明：Paris 首句如今本来就没有音标（挪到了脚注）；去音标规则靠"括号里有没有 IPA 字符"判断，保留 `"[the]"` 这类编辑方括号；父章节在子章节都被删除后变空（如 "Notes and references"），一并删除。

### 朗读
- 朗读引擎抽象为 `SpeechEngine` 协议；`ReadingSession` 管流程，用假引擎做单元测试，另有真引擎冒烟测试。
- 每次交给引擎**整段文字 + 起始位置**（不是剩余文字），云端引擎才能在缓存音频里跳转，不重复付费。
- 暂停用 `pauseSpeaking(at: .immediate)`：`.word` 会在暂停请求到达前跨进下一个词，继续时重读该词。
- 切换语速时从**当前词开头**重读（用户确认保留这个行为）。
- 自动跟随滚动：用户手动滚动后暂停跟随，**停手 3 秒或读到下一段**时恢复；恢复时不立即拉回，等下一个词再滚。
- 系统声音选择：质量优先，同质量下现代声音（`com.apple.voice.*`）优先于老一代 MacinTalk/Eloquence（否则模拟器里会选中 "Fred"），再按口音、名字。
- 语速 4 档（0.75/1/1.25/1.5×），只在播放条上调；上次用的语速会记住作为下次默认值（2026-10-08 去掉了设置页里的 Default Speed 选项，用户说没意义）。
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

### 底部菜单：常驻（Pin）与播放键间距（2026-10-13）
- **播放键间距**：`PlayerBar` 里上一段/下一段与两个 10 秒键之间各加 16 pt（`paragraphGap`），防误触。窄屏账：375 pt 宽的 iPhone 上，模式键 + 速度键 88 + 左右内边距 20 + 播放行 224 + 两处间距 32 = 364，放得下；15 Pro Max 很宽松。
- **常驻**：底部菜单最右边多一个 "Pin / Pinned" 按钮（`pin` / `pin.fill`，和四个标签之间有一条细竖线，它不是标签、没有自己的面板）。键 `readerMenuPinned`（`@AppStorage`，默认关；**没有**放进备份的设置迁移里）。逻辑抽成纯结构 `ReaderMenuVisibility`（`ReaderMenus.swift`，有单元测试）：
  - 不常驻（默认）：和以前一样。点上/下边缘开关菜单；点正文中间、开始滚动、查词（查词时点击会报告中间区）、打开目录/单词本，都收起两个菜单，回到沉浸式。
  - 常驻：底部菜单一直在，点正文、滚动、查词都不会收起它；点底部边缘什么也不做；顶部信息栏仍按沉浸式规则（点正文会收起）。
  - 按下 Pin 时菜单保持现状；取消 Pin 时菜单**留着**，等下一次点正文或滚动才收起（不会在手指刚按下的地方凭空消失）。
- **给正文让位**：常驻时菜单会一直盖在正文底部，所以 `ArticleTextView.bottomObstruction` 把菜单高度（`ReaderView` 用 `PreferenceKey` 量出来，切到字体标签等更高的面板时会跟着变）加到文本视图的 `contentInset.bottom`。自动跟随朗读本来就用 `adjustedContentInset` 算可见区域，所以正在读的句子会保持在菜单上方，文末也能滚到菜单上面。不常驻时是 0，和以前一样。
- **模拟器里滚轮/触控板双指上下滚动不动（2026-10-13，不是 App 的问题）**：用户发现鼠标按住拖动能滚动、滚轮和触控板双指不能。排查：加了滚动日志（拖动每次都正常记录，回调 0.1–0.5 ms，所以不是我们代码太慢）；滚轮时日志里**没有任何**"开始滚动"事件；临时去掉我们两个 `allowedScrollTypesMask = .all` 的横滑手势后依旧不动（所以不是它们抢事件；UITextView/UIScrollView 自带的滚动手势默认 mask 就是 `.all`）；最后用户确认**系统自带的"设置"App 也不能用触控板双指滚动**。结论：模拟器设备本身的输入状态坏了，**用户重启模拟器设备后恢复**，和 App 无关；以后再遇到先重启设备（Device → Restart），不要查 App；真机上手指走触摸事件，和模拟器里的鼠标拖动是同一条路径，不受影响。顺手修了一处退化：重构后每次开始滚动都会无条件写 `menus` 状态触发界面刷新，现在没有菜单可收时不写。日志已撤掉。
- **验证**：模拟器截图看过常驻和不常驻两种状态（布局、间距、Pinned 高亮、文字在菜单上缘被截断而不是被盖住）；11 个单元测试覆盖显隐规则。**未验证**（模拟器没法点）：真的去点 Pin 按钮、点正文/滚动/查词时菜单的行为、常驻时朗读自动滚动是否保持在菜单上方、取消 Pin 后的表现、切到 Font & Size 等较高面板时的位置。

### OpenAI 请求：超时、重试与向后预取（2026-10-13）
- **起因与数据**（用户手机上的 OpenAI Diagnostics 截图，Speech）：111 次请求，成功 106（95%），典型 5.1 s，90% 在 8.3 s 内，最慢成功 51 s，超过 10 s 的 10 次，4 次超时（最近一次 69 s）、1 次网络错误。**正常很快，但有长尾，像是请求卡住而不是生成慢。** 原来：单次超时 60 s（`URLRequest.timeoutInterval`），不重试，用 `URLSession.shared`；预取只有"下一段"，且只在当前段开始时触发一次。结果：一个卡住的请求干等一分多钟再报错；标题段只读 1–2 s，后面的段落要 5–8 s 才生成好，必然要等；预取失败也不重试。
- **超时**：`OpenAITTSClient.attemptTimeout(forCharacters:)` = clamp(8 + 字数/50, 15, 90) s（常见段落 15 s；2000 字 48 s；最长 90 s）。OpenAI 的非流式接口生成完才返回，所以长文本该给更久。专用会话 `OpenAITTSClient.session`（临时配置、不缓存、单次总时长 ≤120 s、每主机 4 连接）取代 `.shared`。
- **重试**（`RetryPolicy`）：超时、网络错误、5xx、429 自动重试，最多共 3 次，间隔 1 s、2 s；429 带 `Retry-After`（秒数）时按它等（上限 15 s）。401、没额度、请求被拒、空响应**不重试**。任务被取消就不再重试。最坏约 15+1+15+2+15 ≈ 48 s 后才报错（原来 69 s 且无重试）。**可能的额外费用**：OpenAI 没有公开说明语音接口里"客户端超时但服务器仍在生成"的请求怎么计费；若按完整生成收费，被重试的那段可能收两次。失败约 4.5%，每段约 1 美分，上限很小。验证办法：设置 → OpenAI Diagnostics 里的请求数对比 OpenAI 用量页。想更保守可以把 `maxAttempts` 降到 2。
- **向后预取**（用户要求"开始读一段时异步缓存下一段，我就不用等"）：`ReadingSession.upcomingTexts()` 在每次开始读一块时（含跳段、快进快退）算出后面要准备的块：约 75 秒语音（按 14 字/秒 × 语速，至少包含下一块）、最多 4 块；`SpeechEngine.prepare(upcoming:)` 取代原来的 `prepare(_:)`，每次调用替换上一次的提示。`OpenAISpeechEngine` 里排队、最多同时 2 个预取（`maxConcurrentPrefetch`），近的先来；正在读的那一块**不排队**，立即开始（可以和 2 个预取同时跑）；已缓存或正在生成的不重复请求；停止朗读丢掉排队中的（已发出的不取消，音频已付费会进缓存）；没有 Key 不预取。**CLAUDE.md 联网规则已同步改**（原来只允许当前段和下一段）。浪费上限：用户读到一半停了，最多多生成约 75 秒语音（约 2 美分）。
- **日志**：`CallRecord` 新增 `attempts`（旧记录没有，当 1 次），多次尝试的请求在 `detail` 里写每次怎么样（"attempt 1 timed out after 15.0 s; attempt 2 ok in 4.2 s"）；诊断页的 Summary 多一行 "Repeated N (M worked)"，Latest 里显示 "3 attempts"，复制的报告里也有。一个请求不管试几次只记一条。
- **没做、原因**：① 把长段落拆成更小的块让第一小块先开始播：会改变块的切分点，已下载（已付费）的音频缓存按块文本哈希命中，超过新上限的段落会失效重新生成，用户在乎已有语音，所以没动 `SpeechChunking`。常见段落（<1000 字）本来就只有一个块。② 对请求"对冲"（15 s 时并行再发一个）：比顺序重试更快但费用更高，等看了重试的数据再说。③ 流式下载/首字节时间：不知道 OpenAI 这个接口是否一边生成一边发，需要真实 Key 才能测；日志里没有首字节耗时。
- **未验证**：真机上重试和预取的实际效果；模拟器里没有 OpenAI Key，只有单元测试（假网络：卡住后重试成功、重试用尽、不可重试的错误、Retry-After、取消、尝试次数的日志、预取的并发上限/顺序/替换/停止、会话的前瞻长度）。

### 暂停后再播放偶尔没声音：日志与自愈；OpenAI 声音加响（2026-10-13）
- **现象**（用户）：OpenAI 声音，没有外部 App 打断，普通点暂停再播放，有时没声音；快进/快退能恢复。
- **推断**：暂停→播放走 `engine.resume()`（只 `player.play()`，且**不重新激活音频会话**，也**丢弃 `play()` 的返回值**），而快进快退走 `speak()`（重新激活会话 + 新建播放器）。所以问题在"继续"这条路径假设播放器和会话还活着。**根因没有确定**：我读完代码没找到能稳定复现的 App 内部竞态，也不能在模拟器里复现。所以先做日志和自愈，下次出问题就有证据。OpenAI 声音下高亮是计时器估算的，沉默时高亮可能仍在走，看起来像在播放。
- **播放日志**（`PlaybackLog`，主线程隔离、内存 + 防抖落盘到 Application Support/Diagnostics/playback-events.json，最近 600 条，测试里不记录）：设置 → Playback Log（`PlaybackDiagnosticsView`），可 "Copy Report"（带毫秒的纯文本）和清空。记录：`ReadingSession` 的 play/pause/skip/jump/stop/失败/静音重启（带 state、块号、词位置、是否有活动 utterance）；引擎的 speak/pause/resume（带播放器 `isPlaying/currentTime/rate` 和音频会话的类别、模式、是否有别的 App 在出声、音量、输出设备）；`play()` 的返回值；`AudioSessionMonitor` 记录系统的打断（原因、shouldResume）、路由变化（原因、上一个设备）、媒体服务丢失/重置、锁屏/解锁、进后台/回前台、内存警告。不含文章文字。
- **自愈**：`OpenAISpeechEngine.resume()` 先 `SpokenAudioSession.activate()`；`start()` 之后起一个看门狗（`watch`）：500 ms 后播放头（`currentTime`）没前进到应有距离的 1/4（或 `isPlaying` 为假）就判定静音，先重新激活会话再 `play()` 一次，再 500 ms 仍不动就发新事件 `SpeechEvent.stalled`，`ReadingSession` 按当前词重新 `speak()`（OpenAI 有缓存，不重复花钱）；连续 2 次重启仍静音（`maxStallRestarts`）就暂停并提示 "Sound isn't coming out…"；用户的任何操作或一段读完会重置次数。系统声音引擎同样在 `resume()` 里重新激活，并在继续后 2.5 s 没有任何朗读回调时报 `stalled`。`AudioClip.play()` 现在返回 Bool、多了 `isPlaying`。
- **要看什么**：下次再没声音时，设置 → Playback Log → Copy Report 发给我。关键看 `resume` 那一行的 `session[...]`（类别是不是 Playback、输出设备是什么）、`play() -> true/false`、有没有 `stall` 行（自愈有没有触发、第几次恢复）、前面有没有 `route`/`session`/`app` 事件。**未验证**：自愈在真机上是否真的触发和恢复（模拟器里只有单元测试：假播放器冻结、拒绝播放、重试后恢复、暂停取消检查）。
- **响度**：量过模拟器里 10 段真实 OpenAI 音频（marin，24 kHz 单声道）：平均响度约 −21 dBFS（只算非静音部分），峰值约 −3 到 −8 dBFS，所以比普通 App 小一截，切过去会觉得突然变大。`AVAudioPlayer.volume` 最大 1.0 放不大，所以打开片段时放大音频本身（`LoudnessBoost`）：测量非静音部分的 RMS 和 99.9 百分位峰值，加固定增益（≤10 dB，且 99.9 百分位峰值不超过 0.9），再用平滑限幅器（拐点 0.8，tanh）处理极少数冲过满幅的峰值，输出 16 位 WAV 交给 `AVAudioPlayer(data:)`。**缓存里的 mp3 不动**，所以备份、缓存文件名、已下载的语音都不受影响；只放大不减小；处理在后台线程（`@concurrent`，Release 下 57 秒音频约 60 ms）。
- **档位**（设置 → Voice，API Key 下面，键 `speechLoudness`，随备份迁移）：Normal（原样）、Louder（目标 −17 dBFS，约 +3.5 dB）、**Loudest（默认，目标 −14 dBFS，约 +6.5 dB，振幅约 2.2 倍）**。实测 10 段：Loudest 后平均响度 −14.1 到 −14.8，0 个样本被硬削顶；峰值高的片段（如 650015de）增益被峰值上限卡在约 6 dB，所以只到 −14.8。从下一段开始生效，试听按钮也走同一条路径。**只对 OpenAI 声音有效**；iPhone 系统声音的 `utterance.volume` 上限就是 1.0，无法放大。**未验证**：真机上听感，和别的 App 的实际响度差；音乐类 App 通常平均响度 −10 到 −14 dBFS、峰值顶到 0，所以 Loudest 之后仍可能略小于它们，需要的话可以再加一档或调高目标（代价是限幅器动作更多）。

### 自己的词典页，取代系统词典（2026-10-13）
- **起因**：① 系统词典的内容区是另一个进程画的，触摸 App 收不到，下滑关不掉（试了三版都只能靠小横条/标题栏拖动区）；② 苹果词库释义不好用、没装英汉词典就没有中文。AI 讲解页和翻译页因为是我们自己的 SwiftUI，所以任意位置下滑都能关。**结论：点词直接弹自己的词典页，下滑关闭和 AI 页一样。**
- **离线词库**：完整 ECDICT（MIT，77 万词条，用户明确要完整版不要裁剪版）。`tools/make_dictionary.py` 把官方 `ecdict.csv`（66 MB，不进仓库，下载命令在脚本注释里）转成 `WikiReader/Resources/ecdict.sqlite`（77.5 MB，压缩后约 30 MB，**已提交进 git**；重建会再往仓库里加一份约 30 MB，别随便重建）。表 `entries` 以 (lower, word) 为主键、WITHOUT ROWID；字段：音标、英文释义、中文释义、柯林斯星级、Oxford 3000、考试标签、词频、`exchange`（词形和原形）。丢掉 pos/detail/audio。放在同步文件夹里，自动进 App 资源。
- **查询**：`DictionaryDatabase`（`SQLite3` 系统库，每次查询打开只读文件、查完关，没有共享连接所以不用加锁）；`DictionaryEntry` 解析中文/英文行（库里的换行是两个字符 `\n`）、词形（`0:` 是原形，`p/d/i/3/r/t/s` 是变形）、考试标签、显示用音标（ECDICT 的 schwa 是西里尔字母 `ә`，显示时换成 `ə`，并去掉 `^`）。`DictionaryLookup.bundled` 取代 `.system`，候选顺序不变；变形词（`studies`）同时显示原形（`study`）的释义。已知：ECDICT 没有首字母大写的专有词条（March/Turkey 显示的是普通名词义）；`CCP` 这类缩写词义不对；中文释义偏短，语境里的准确意思仍靠 ✨AI。
- **联网（用户同意，CLAUDE.md 已改）**：打开词典页时请求 Wiktionary（`WiktionaryClient`，6/12 秒超时，只发单词，结果存 Application Support/Definitions，失败静默并给"Retry"）；点喇叭时 `WordPronouncer.pronounce` 先取 Commons 的真人录音 mp3（`WordAudioClient`，缓存 Application Support/WordAudio，没有或失败就用系统美式声音）。**dictionaryapi.dev 试过并放弃**：2026-10-13 实测，只有缓存过的词能秒回，其余都卡约 20 秒后 522。Commons 的 mp3 有时返回 429（转码限流），所以失败回退很重要。Wikimedia 的 User-Agent 带邮箱，**绝不能发给 Wikimedia 以外的服务**。
- **界面**（`WordCardView` + `WordCardModel`，`WordCardHostingController` 负责"真正关闭"的回调）：单词 + 音标 + 喇叭、Collins 星/Oxford 3000/考试标签、中文、原形、词形、英文（在线的到了就替换离线的）；底部固定 ✨AI、收藏、"iPhone Dictionary"（在卡片上再弹系统词典）。收藏时如果没有 AI 释义，存词典里第一行中文（≤40 字）。查词后恢复朗读的逻辑（`onDismiss`）不变。
- **验证**：模拟器截图看过三种情况（`shirk`、变形词 `studies`、库里没有的词）；真实网络下在线释义加载并缓存成功；单元测试（数据库/词条/Wiktionary/录音/缓存/卡片模型）。**未验证**：点喇叭的真人录音（模拟器没点击）、AI 按钮和收藏按钮的点击、下滑关闭本身、真机上的字号与排版、深色以外的主题、`WordExplanationView` 作为嵌套 sheet 弹在卡片上的表现。
- 取代了下面两节里关于"叠在系统词典上的浮动按钮"和"拖动区 dragStrip"的做法（代码已删，`PronouncingDictionaryViewController` 不存在了）；"Search Web 去不掉"也不再相关。**不要重复做**：用户否决过"点词先弹词卡 + 自动发音"，现在点词不会自动发音，只有按喇叭才发。

### 词典界面：发音与 AI 讲解（2026-10-08，已被上面取代，保留作历史）
- 系统词典的内容改不了：不能加按钮，也不能去掉 "Search Web" / "Manage Dictionaries"。所以做成它的子类，在右下角叠两个浮动按钮：`✨ AI` 和喇叭。
- 点词直接弹词典，**不自动发音**；按喇叭才读被查的词，固定美式（en-US）本机声音（设置里选的声音是美式就用它，否则用最好的美式声音）。读单词不 `deactivate` 音频会话，避免影响暂停中的文章朗读。
- AI 讲解：点 AI 才请求 OpenAI，只发单词和所在句子，用设置页保存的同一个 Key。返回词性、中文释义、用法说明、整句翻译、3 个中英例句。无 Key、超时、限流、额度用完都有明确提示。**未做缓存**：重复点同一个词会重复请求（单次约千分之几美分）。
- 联网规则已写进 CLAUDE.md："AI 讲解/翻译只在点按钮时请求，只发单词/所选文字"。
- 抓取 Wikipedia 改用专门的会话：15 秒无响应、总共 30 秒就报"超时"（原来 `URLSession.shared` 默认 60 秒/7 天，网络差时像无限转圈）。

### 阅读页改版（2026-10-08）
- **沉浸式**：默认隐藏状态栏、导航栏、播放条。点屏幕最上方（含灵动岛那条安全区，用一个看不见的 SwiftUI 点击条 `topTapStrip` 覆盖）出顶部菜单；点最下方出播放条；中间点词仍查词，同时收起菜单；开始滚动也收起。朗读出错时错误条始终显示。文本视图只在底部忽略安全区（顶部留出灵动岛，第一行不会被挡）。隐藏导航栏会关掉左边缘滑动返回，用 `SwipeBackEnabler` 重新打开（**未验证**）。
- **菜单（2026-10-09，取代之前所有版本的描述）**：
  - 顶部 `ReaderTopInfoBar` 只放信息：标题、读到百分之几、当前章节 · 第几段/共几段 · 还剩几分钟，下面一条细进度条（`ReadingProgress`，按字数估算，`ReadingSession.charactersPerSecond` = 14 字/秒 × 语速）。没有按钮。
  - 底部 `ReaderBottomMenu`：四个并列的标签 **Playback、Font & Size、Theme、Layout**，永远有一个展开（默认 Playback）。**播放控制只在 Playback 标签下显示**（`PlayerBar`：左边播放模式按钮（**点一下直接切到下一个模式**：顺序 → 循环 → 随机 → 顺序，屏幕正中弹出约 3 秒的提示 `ReaderToast`，不再弹菜单），中间上一段、快退 10 秒、播放、快进 10 秒、下一段，右边语速菜单）；播放不放进其他设置里，也不是常驻的一行（用户明确要求，说了两次）。**上次用的标签会记住**（`readerMenuTab`），下次打开菜单就在那个标签上。
  - 主题（Auto/White/Sepia/Dark）各自带一套菜单配色（栏底色、强调色、强调色上的图标色，见 `ReaderStyle.Theme`）：米黄配赭红，白色配蓝，暗黑配琥珀色，Auto 用系统色。段末 "Translate" 也用主题强调色。暗黑沿用柔和炭灰，界面里不再有 Soft–Deep 滑块（`darkLevel` 设置和备份字段还在，只是没有入口）。
  - 旧的悬浮玻璃菜单、`ReaderTopMenu`、排版 sheet 都已删除。
- **播放模式**（`PlaybackMode`，键 `playbackMode`，随备份迁移）：Sequential = 当前文章读完后接着读文库里的下一篇（按文库列表顺序，最后一篇读完就停）；Loop = 当前文章从头再来；Shuffle = 读完随机换另一篇（只有一篇时重读）。切换文章靠 `ReaderView` 外层包装：`.id(文章 + generation)` 重建里面的 `ArticleReader`，新文章从头自动开始读；旧会话读完时已经停了，不会和新文章抢音频会话。
- **快进快退 10 秒**（`ReadingSession.skip(seconds:)`）：按估算的字符数前后移动，可以跨段，落在词首；系统声音和 OpenAI 都用这个估算，会有误差。播放中从新位置接着读；暂停或停止时只移动起点。
- **多选翻译**：长按选词、拖手柄可跨段。选择菜单自己做（AI Translate / Read From Here / Copy），不用系统菜单（系统的 Look Up / Share 会带出网络搜索）。**原来的"长按某段开始朗读"改成了选择菜单里的 Read From Here**（SPEC F5 已同步）。
- **段末翻译**：每个段落（不含标题）末尾追加小号蓝色 "Translate"，是段落富文本的一部分但**不在块范围内**（`translateBlock` 属性；不参与朗读、高亮、取词、选中文字）。点它和多选翻译共用同一个翻译面板；没做成段落下方内联展开（要改整篇布局，风险大）。
- 翻译走 `OpenAIChatClient`，结果按（模型 + 原文）缓存到 Application Support/Translations，同一段再看不重复请求，离线也能看缓存。上限 6000 字符，超出只翻前面并提示。

### 查词/翻译后的播放与下滑关闭（2026-10-09）
- **查词、翻译、单词本里点词**：开始前如果正在播放，关掉词典/面板后自动接着播；如果是用户手动暂停的，保持暂停等按播放。规则在 `LookupResume`（`ReadingSession.swift`），`ArticleReader` 的 `pauseForLookup` / `resumeIfPausedForLookup` 用它。词典用 `DictionaryPresenter.present(…, onDismiss:)`（`PronouncingDictionaryViewController.viewDidDisappear` 里判断 `isBeingDismissed`，AI 面板盖上去或移开不算关闭），翻译用 `.sheet(item:onDismiss:)`。这取代了之前"查词后一律保持暂停"的行为（SPEC F4 已改）。
- **下滑关闭（第三版，2026-10-09，最终结论）**：系统词典的内容区是**另一个进程**画的、也由它处理触摸，**这块区域的触摸 App 收不到**，所以任何加在宿主视图上的手势（包括整页下滑）都拿不到从单词/释义上开始的拖动，用户实测也证实了（第二版整页手势无效）。能用的只有：① 系统面板自己的小横条；② 我们在**标题栏**上盖的一条透明拖动区（`dragStrip`，高 104pt、宽度到关闭按钮左边为止，向下拖超过 40pt 或速度够快就 `dismiss`），比只有小横条好点得多。另外 `isModalInPresentation` 和 `modalPresentationStyle` 仍重写固定，防止系统改回去。**要做到整页下滑关闭只有一个办法：让词典内容区不再响应触摸（`isUserInteractionEnabled = false`），代价是不能点词条展开、不能点 Search Web/Manage Dictionaries，长词条也没法滚动**，没做，等用户决定。
- 下滑关闭（第一版思路）：词典显式设成 `.pageSheet`、`isModalInPresentation = false`、`[.medium, .large]` 两档、显示顶部小横条（grabber）；翻译和 AI 讲解面板也显示小横条。**未验证**：下滑是否真的能关掉系统词典（它是系统进程里的内容，没法在模拟器里点），请真机试；如果还是关不掉，说明系统词典自己拦了手势，要换办法。

### OpenAI 请求记录（2026-10-09）
- 起因：用户在真机上遇到过几次朗读"缓冲时卡住、提示超时"，但没留下记录，没法判断成功率。现在每次 OpenAI 请求都记一条（`OpenAICallLog`，actor，存 Application Support/Diagnostics/openai-calls.json，只保留最近 500 条）：时间、类型（Speech = 朗读音频；AI Text = 单词讲解和翻译）、大小（朗读是字数，AI 文字是请求体字节数）、耗时、结果（成功/超时/网络错误/限流/额度用完/Key 被拒/…）、失败时的简短说明。**不记任何文字内容**。
- 记录点：`OpenAITTSClient.synthesize` 和 `OpenAIChatClient.send`（都带 `log` 属性，默认 `.standard`；测试里 `.standard` 自动关闭，不会污染真实记录）。TTS 的系统超时现在单独算 `OpenAITTSError.timedOut`（原来混在 network 里）。
- 查看：设置 → OpenAI Diagnostics（`OpenAIDiagnosticsView`）：请求数、成功率、典型耗时、9/10 请求的耗时上限、最慢成功耗时、超过 10 秒的次数、失败原因分布、最近 30 条；"Copy Report"复制成纯文本，可以直接贴给 Claude；"Clear Log"清空。
- **未验证**：诊断页的实际样子（只写了代码和测试，没截图）；真机上记录是否正常落盘。
- **下一步（已在 2026-10-13 做了，见"OpenAI 请求：超时、重试与向后预取"）**：缩短超时、自动重试、多提前准备几段。"把长段落拆小"没做（见那一节的原因）。

### 目录与手势（2026-10-09）
- **右划 = 打开目录**（`ContentsView` 从左边滑入，占满全屏）；左划关闭目录；**左划（目录没开时）仍是打开单词本**，右划（单词本开着时）关单词本。选中了文字时横向滑动一律不处理（`hasSelection`），免得拖选择柄时误触发。
- **系统的左边缘滑动返回已关闭**（会和右划冲突）。返回靠顶部栏最左边的返回按钮（`ReaderTopInfoBar.onBack`，`dismiss()`）。`SwipeBackEnabler(onSwipe:)` 现在负责关掉系统手势并上报左/右划；用 `liveCount` 计数，换文章时旧 reader 晚消失也不会把系统手势提前打开。
- **目录页是一条时间轴**（`ContentsView`）：顶部是文章标题 + "N sections · about M min"；左边一根轨道，大章节是带编号的圆节点（开头是图标）、周围留间距，小节是小圆点并缩进；已读部分的轨道和节点染成强调色，当前节是实心节点 + 高亮条 + "Reading now"；每行右边是该节正文的阅读时长（至少 1 min，按 14 字/秒）。节点下垫一层页面底色，避免轨道穿过半透明节点。
- **目录**（`ArticleOutline`）：由标题块生成，开头没有标题的话补一个 "Introduction"；缩进最多两层；每条显示读到全文的百分之几；当前章节 = 当前块之前最后一个标题。点一节：`ReadingSession.go(to:)`（播放中就从那里接着读，暂停/停止就只移动位置）+ `ArticleTextView.ScrollTarget`（按 token 去重，滚到那个块）。
- 截图验证过目录面板和顶部栏（米黄主题）；**未验证**：右划/左划手势本身、点章节跳转、返回按钮。

### 后台播放与锁屏（2026-10-09）
- **后台**：`Config/WikiReader-Info.plist` 只含 `UIBackgroundModes = [audio]`，在 `project.pbxproj` 里用 `INFOPLIST_FILE` 指向它，和自动生成的 Info.plist 合并（`INFOPLIST_KEY_UIBackgroundModes` 不支持数组，试过，不生效）。音频会话本来就是 `.playback / .spokenAudio`。已确认构建出的 Info.plist 里有 `UIBackgroundModes`，启动屏等生成的键都还在。
- **锁屏 / 控制中心**（`NowPlayingController`，`ArticleReader` 里创建、离开时 `teardown`）：
  - 标题 = 正在读的**那一句**，艺术家 = 文章标题，专辑 = 当前章节；锁屏大图（`LockScreenArtwork`）画的是上一句（淡）、当前句（白、粗）、下一句（淡），字号自动缩放到放得下——这是锁屏上唯一有空间放文字的地方。每换一句重画一次。
  - 按钮：播放/暂停、上一段/下一段、快进/快退 10 秒，都直接调 `ReadingSession`。进度条只是显示（按字数估算全文时长和已读时长），不能拖。
  - 电话/闹钟打断、拔耳机时自动暂停。
  - **不靠 SwiftUI 更新**（锁屏时视图不刷新），用 `withObservationTracking` 直接盯 `ReadingSession`。
  - 新旧 reader 交接时旧的 `teardown` 可能晚于新的启动：只移除自己注册的命令，且只有自己仍是 `active` 才清锁屏信息。
- **未验证（模拟器无法验证，需真机）**：锁上屏幕后是否真的继续读；锁屏上的标题、大图、按钮是否显示并能用；打断后的行为。文字卡只在测试里渲染出图看过。
- **已知风险**：跨文章的顺序/随机播放靠 SwiftUI 重建 reader 来切换，**锁屏状态下视图不刷新，文章读完后很可能不会接着读下一篇**（循环模式在会话里处理，不受影响）。真机验证后如果确实停了，要把"换文章"从视图里挪到会话层。

### 单词本（2026-10-08 晚）
- 每篇文章自己一份单词本：`Article.savedWordsData`（JSON，和 blocks 一样存成一个字段，带默认值，旧数据库原地升级）；`SavedWord`（单词、查询词、所在句子、时间），同一个查询词（不分大小写）只算一条。
- 收藏入口：系统词典右下角的书签按钮（和 AI、喇叭一排），已收藏时是实心，再点取消。
- 查看入口：阅读页在正文上**向左滑**（明显横向、距离超过 80pt 才触发，不影响上下滚动），Saved Words 面板**从右边滑进来并占满全屏**（原来的底部 sheet 已换掉；`ReaderView.savedWordsPanel`），点 ✕ 或在面板上向右滑收回；**右滑的层级**：面板打开时右滑（触摸或触控板双指）先收起面板，再右滑才返回文库——`SwipeBackEnabler(onSwipeBack:)` 在面板打开时关掉系统返回手势、改用自己的右滑识别（`allowedScrollTypesMask = .all`，认触控板）。**未验证**；点一行打开该词的词典，左滑一行删除。**滑动手势和面板里点词都没法在模拟器自动化，未验证。** 没有可见的按钮入口（只有手势）。
- 正文里收藏过的词（原词或查询词，不分大小写、带 `'s` 也算，整词匹配）用淡橙色底标出；朗读高亮、点词闪烁盖在它上面，结束后恢复淡橙色。收藏/取消后下次回到阅读页重算（`ArticleDocument.ranges(ofWords:)`，只在收藏集变化或文章重建时算）。只标正文块，不标文章大标题。截图验证过浅色主题；深色主题的颜色没看。
- 列表只显示单词和中文释义，不再显示所在句子（句子仍存着，给 AI 用）。**系统词典的释义文字 App 读不出来**，所以释义来自 AI：在词典里点过 ✨AI 的词，收藏时/之后自动带上释义；没有释义的行有 "Meaning" 按钮，点了才请求 OpenAI（不改联网规则：只在点按钮时、只发单词和句子）。用户没指定来源，这是我的默认选择；若想收藏时自动请求，要先改 CLAUDE.md 联网规则。
- 左滑手势加了 `allowedScrollTypesMask = .all`，让模拟器触控板双指滑动也能触发（原来只有按住鼠标拖才行）。**未验证**。
- 15 个单元测试（`SavedWordTests`、`SavedWordHighlightTests`、`SavedWordMeaningTests`）。

### 备份与迁移（2026-10-08 晚）
- 目的：重装/换手机时带走文章、单词本和**已生成（已付费）的 OpenAI 音频**。免费开发者账号（Personal Team）没有 iCloud 能力，所以走"导出一个文件 → AirDrop/文件 App → 另一台导入"。入口：设置 → Backup & Transfer（`LibraryBackupView`）。
- 文件 `.wikireader`（`ArchiveFile.swift`）：自定义单文件容器（8 字节魔数 `WIKIRDR1` + 各文件依次拼接 + JSON 索引 + 8 字节索引长度）。不用 zip（系统没有公开的解压接口，也不引入第三方）。边写边流式拷贝，大音频不进内存。
- 内容（`LibraryBackup.swift`）：`library.json`（文章：标题、URL、添加时间、正文块、阅读位置、单词本；设置）+ `audio/<hash>.mp3` + `translations/<hash>.json`。**不含 OpenAI Key，也不含系统声音 identifier**（各设备不同）。
- 音频文件名 = SHA256(模型+声音+风格+文本)，与设备无关，所以拷过去 App 自己就能命中缓存，不需要映射。导出时按所选文章的每个块 × 13 个 OpenAI 声音重新算文件名，只带这些文章用得上的音频；翻译缓存全部带（体积小，选中文字的翻译也说不清属于哪篇）。**前提：文章正文原样导入、声音/模型/风格没变；以后改了 `SpeechChunking` 或风格说明，旧音频会失效。**
- 导入合并：按标题（去空白、不分大小写）匹配；已有的文章**不覆盖**，保留本机阅读位置，只补上缺的单词本词条（本机没释义的词用备份里的释义）；没有的文章新增。音频/翻译文件已存在就跳过。设置**只在本机还没有任何文章时**才应用。缓存文件名必须是 64 位小写十六进制 + 扩展名，其它一律忽略（防止恶意文件写到别处）。格式版本号 1，更新版本的备份会被拒绝。
- 测试：11 个（容器往返、截断/垃圾文件、整库往返、重复导入、合并、设置、音频匹配、文件名安全、新版本）。
- **未验证**：设置页里导出后弹出的分享面板（AirDrop/存到文件）、导入时的文件选择器、真机上用 AirDrop 传文件。界面只截图看过备份页。
- 没做：点文件直接用 WikiReader 打开（要在 Xcode 里声明文档类型）；导出文件放进 Finder 文件共享。

### App 外观（2026-10-08 晚）
- 设置页最上面一个 Appearance 分段：System / Light / Dark（`AppAppearance`，键 `appAppearance`，随备份一起迁移）。实现：根视图 `preferredColorScheme` + 给所有 window 设 `overrideUserInterfaceStyle`（后者让 UIKit 弹出的系统词典、alert 也跟着变）。
- **坑**：设置页是 sheet，弹出期间不会跟着窗口变；所以 `SettingsView` 自己也带 `.preferredColorScheme(appearance.colorScheme)`，根视图是个单独的 `RootView`（`@AppStorage` 放在 `App` 结构体里不会可靠地触发更新）。运行中切换 Light↔Dark 用截图验证过（用 App 内定时改 UserDefaults 模拟点选）。注意：`xcrun simctl spawn … defaults write` 写的不是 App 自己存设置的那份，测外观别用它。
- 阅读页自己的主题（Auto/Light/Sepia/Dark）还在：它的 Auto 跟随 App 外观，选 Light/Sepia/Dark 则只改阅读页。
- 截图验证过：深色（设置页）、浅色（文库页）。**未验证**：System 随 iPhone 切换时实时跟随、系统词典界面在深色下的样子、阅读页 Auto 在 App 深色下的样子。

### 其他
- 模拟器默认用 iPhone 15 Pro Max（和另一个项目共用）。App 图标：蓝色渐变底 + 白色书本 + 声波，浅色、深色、着色三个版本，由 `tools/make_icon.swift` 生成。

## 4. 验证状态

| 内容 | 状态 |
|---|---|
| 单元测试（303 个，8 个词形还原测试在模型未下载时失败） | 15 Pro Max 模拟器全过 |
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
- [ ] 锁屏/后台朗读、Share Extension。（生词本已做，见上。）

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
