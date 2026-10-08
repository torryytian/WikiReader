# WikiReader 需求文档

> 暂定名 WikiReader。这份文档既是给 Claude Code 的需求说明，也是我自己的备忘；需求有变化直接改这里。

## 1. 一句话描述

输入一个英文 Wikipedia 页面，App 抓取正文、用自然的人声朗读；阅读时点任意单词，直接查词典。

## 2. 使用场景

- 边听边看：朗读时高亮当前单词，页面自动跟着滚动。
- 自己读：遇到不认识的词点一下，弹出词典（最好能看到英汉释义）。
- 文章保存在本地，之后离线也能读、能听。

先只给我自己用，不上架。

## 3. 功能需求

### F1 添加文章

- 首页右上角「+」，弹出输入框，支持三种输入：
  - 桌面版链接：`https://en.wikipedia.org/wiki/Albert_Einstein`
  - 手机版链接：`https://en.m.wikipedia.org/wiki/Albert_Einstein`
  - 直接输入标题：`Albert Einstein`
- 正确处理链接里的 `#锚点`、URL 编码（如 `C%2B%2B` → `C++`）和下划线。
- 跟随重定向：输入 `Einstein` 应该得到 `Albert Einstein`。
- 抓取时显示加载状态；页面不存在、网络失败时给出明确的错误提示。
- 只支持英文 Wikipedia（en.wikipedia.org）。

### F2 正文清洗

目标：只留下适合阅读和朗读的正文。

- 保留：导语、各级章节标题、正文段落。
- 删除以下章节及其所有子章节（不区分大小写）：See also、References、Notes、Footnotes、Citations、Sources、Bibliography、Works cited、Further reading、External links。
- 删除首段里的发音信息（方括号或斜杠里的 IPA 音标、"listen" 等），保留生卒日期之类的正常内容，不残留 `( )`、`( ; )` 这样的空括号。
- 删除数学公式残留（含 `{\displaystyle` 的片段）。
- 不出现 `[1]`、`[citation needed]` 之类的引用标记。
- 合并多余的空行和空格。

### F3 阅读页

- 显示文章标题、章节标题（按层级区分字号）和正文段落，字号适合手机阅读，支持深色模式。
- 打开文章时回到上次读到的段落（见 F6）。

### F4 点词查词典

- 单击正文里的任意单词，弹出 iOS 系统词典。
- 先判断原词有没有释义；没有就换成词形还原后的原形再查（`running` → `run`，`studies` → `study`）。
- 都查不到也照样弹出词典界面：它会显示"无释义"，并提供管理、下载词典的入口。
- 被点的单词短暂高亮，作为点击反馈。
- 点击标点、数字、空白处没有反应。
- 朗读中点词：自动暂停朗读；关掉词典后保持暂停，按播放从暂停处继续。

### F5 朗读

- 底部播放条：播放/暂停、上一段/下一段、语速（3–4 档即可）。
- 按播放时，从上次停下的地方继续；没有记录就从开头读。
- 从某一段开始朗读：长按选中文字，在弹出的菜单里点 Read From Here（长按已用于选择文字，见 F3）。
- 朗读时高亮当前单词，页面自动滚动，让正在读的段落保持在屏幕内。
- 一段读完自动接下一段，全文读完后停止。
- 章节标题也读出来，读完稍作停顿。
- 只用英语声音，按质量优先选 Premium > Enhanced > 默认；设置页可以选具体声音并试听。
- 设备上没有 Premium 声音时，在设置页提示去 iPhone「设置 → 辅助功能 → 朗读内容（iOS 26 里可能叫 Read & Speak）→ 声音」下载。

### F6 文章库

- 首页是已保存的文章列表（标题、添加时间），左滑删除。
- 文章内容存本地，离线可读可听。
- 每篇文章记住上次读到/听到的段落。

### F7 设置页

- 朗读声音：列出已安装的英语声音并标注质量，可以试听。
- 默认语速。
- 简短说明：如何下载 Premium 声音；如何在 iPhone「设置 → 通用 → 词典」里启用英汉词典。

## 4. 开发阶段与验收标准

一次只做一个阶段。每个阶段结束时必须能编译、能在模拟器里运行，并通过下面的验收项，再进入下一阶段。

### 阶段 0：工程初始化

- 部署目标设为 iOS 17.0；按 CLAUDE.md 建好目录结构；加 `.gitignore`；首页先放一个空列表占位。
- 验收：模拟器里能启动，看到空的首页。

### 阶段 1：抓取、清洗、显示、保存（F1、F2、F3，以及 F6 的基础保存）

- 文章一抓下来就用 SwiftData 存起来，首页列表直接读数据库，避免先做内存版、后面再迁移。
- 验收：
  - 输入 `https://en.wikipedia.org/wiki/Albert_Einstein`，能看到标题、章节标题和正文。
  - 添加的文章出现在首页列表里；杀掉 App 再打开，文章还在。
  - 正文里没有 References、External links 等章节，没有引用标记。
  - `Paris` 词条首句的音标被去掉，没有空括号残留；`Pythagorean theorem` 词条里没有 `{\displaystyle`。
  - 输入不存在的页面（如 `Asdfqwerzxcv123`）有明确提示，App 不崩溃。
  - URL 解析和正文清洗有单元测试，覆盖 F1、F2 列出的情况，全部通过。

### 阶段 2：点词查词典（F4）

- 验收：
  - 点正文里的单词能弹出系统词典；点 `studies`、`running` 这类变形词能查到原形。
  - 点标点或数字没有反应。
  - 模拟器里可能还没下载词典，显示"无释义"属正常，最终以真机为准。

### 阶段 3：朗读（F5）

- 验收：
  - 能播放、暂停、切段、调速；长按某段能从该段开始读。
  - 朗读时当前单词高亮，页面自动跟随滚动。
  - 朗读中点词会暂停朗读。
  - 音质和高亮是否同步以真机为准（模拟器里的声音和高亮回调可能与真机不同）。

### 阶段 4：文章库完善与设置（F6 其余部分、F7）

- 验收：
  - 断网时也能打开已保存的文章并朗读。
  - 重新打开文章会回到上次的段落。
  - 首页左滑能删除文章。
  - 设置页能切换声音、试听，选择会被记住。

### 阶段 5：以后再说（可选）

- 锁屏、后台继续朗读，锁屏界面显示播放控制。
- 从 Safari 分享 Wikipedia 页面直接导入（Share Extension）。
- 生词本：记录查过的词和所在的原句。苹果规定系统词典界面不能用来展示单词列表、做独立词典或转载词典内容，所以生词本只存单词和原句，释义另想办法（比如下面的 AI 释义）。
- AI 释义：调用大模型解释"这个词在这句话里是什么意思"。
  - 可选：联网词典兜底（如 Wiktionary REST API，免 Key、英英释义），需同时调整 CLAUDE.md 中"只在添加文章时请求"的规定。查词的取词和选词逻辑不变，只替换释义的展示层。
- 云端 TTS（见 5.3）。

## 5. 技术方案

### 5.1 Wikipedia 抓取

- 用 MediaWiki Action API 的 TextExtracts 接口取纯文本：

  ```
  https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&exsectionformat=wiki&redirects=1&format=json&formatversion=2&titles=<URL 编码后的标题>
  ```

- 返回的纯文本里，章节标题形如 `== History ==`、`=== Early life ===`，等号个数就是层级。
- 页面不存在时，返回结果里会标记 missing，据此给出"页面不存在"的提示。
- 每个请求都要带 User-Agent（格式和内容见 CLAUDE.md）。Wikimedia 从 2026 年起对 API 统一限流，不带联系方式的请求会被归为"未识别"，配额很低。
- 只在用户添加文章时请求，不预取、不批量抓。
- Wikipedia 正文采用 CC BY-SA 4.0 授权。自己用没问题；以后如果要分发，阅读页需要注明来源和许可。

### 5.2 朗读（v1：系统 TTS）

- 用 `AVSpeechSynthesizer`，每个内容块（标题或段落）一个 `AVSpeechUtterance`，方便跳段和定位。
- 逐词高亮用 `AVSpeechSynthesizerDelegate` 的 `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)` 回调，把段内的 range 换算成全文位置。
- 选声音：用 `AVSpeechSynthesisVoice.speechVoices()` 列出英语声音，按 `quality` 排序，保存用户选中的 voice identifier。不要靠 `AVSpeechSynthesisVoice(language:)` 自动选声音（iOS 26 上出现过它忽略用户所选声音的问题）。
- 已知现象：高亮偶尔会跳过个别短词，属于系统行为，不必追。
- 朗读引擎抽象成协议（比如 `SpeechEngine`：从某个块开始播放、暂停、继续、停止、设置语速，加上"当前朗读位置"的回调）。v1 只有系统实现，以后加云端实现不用改界面。

### 5.3 以后：云端 TTS（备选）

| 方案 | 自然度（主观） | 费用 | 逐词高亮 |
|---|---|---|---|
| 系统 Premium 声音（v1） | 不错，但能听出合成感 | 免费、离线 | 支持 |
| OpenAI TTS | 更接近真人 | 约每分钟音频 1.5 美分（英文约 1000 字符 ≈ 1 分钟） | 不返回时间戳，只能按段高亮 |
| ElevenLabs | 很接近真人 | 按套餐计费 | 返回字符级时间戳，可以逐词高亮 |

不管选哪家：

- 按段切分请求（单次请求有长度上限）。
- 生成的音频按文章缓存到本地，不重复生成、不重复付费。
- API Key 由我在设置页输入、存 Keychain，绝不写进代码或提交到 git。以后如果上架，Key 不能放在 App 里，需要自己的服务端转发。

### 5.4 查词

- 用 `UIReferenceLibraryViewController(term:)`，以 sheet 方式弹出（SwiftUI 里用 `UIViewControllerRepresentable` 包一层）。
- 查之前用 `UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm:)` 判断有没有释义。
- 词形还原：`NLTagger`，tag scheme 用 `.lemma`。
- 英汉释义来自系统词典里的英汉词典，需要我在 iPhone「设置 → 通用 → 词典」里勾选（比如"简体中文-英文"）。

### 5.5 阅读页实现建议（有更好的方案可以先提出来）

- 正文用一个不可编辑、可滚动的 `UITextView`（`UIViewRepresentable` 包装）承载整篇文章。点击取词（`closestPosition(to:)` 配合 `tokenizer` 按单词粒度取范围）、逐词高亮（改背景色）、自动滚动（`scrollRangeToVisible`）都比较好做，长文章的性能也稳定。
- 维护"内容块 → 全文字符区间"的映射，供朗读定位、高亮换算和"长按某段开始朗读"使用。

### 5.6 数据模型（草案）

- `Article`（SwiftData）：标题、来源 URL、添加时间、内容块、上次读到的块序号。
- 内容块：Codable struct，字段为类型（标题/段落）、层级、文本。为稳妥起见，可以把内容块数组编码成 JSON `Data` 存在一个字段里。

## 6. 暂不做

登录和账号、iCloud 同步、其他语言的 Wikipedia、iPad 和横屏适配、上架 App Store。
