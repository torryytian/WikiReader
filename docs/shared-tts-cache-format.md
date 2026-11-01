# 共享 TTS 音频缓存格式（iOS WikiReader ↔ Chrome 插件）

> 状态：**已定稿 v1（2026-11-01）**，两端已对齐。来源：iOS 版 WikiReader 现有实现。
> Chrome 插件已按本格式实现（/Users/bytedance/Desktop/claude/chrome_extension_reading，`src/core/wiki/` 是 iOS 清洗器的 TS 移植）。
> **改动规则**：key 公式、切块、正文清洗、URL 规范化任何一处要改，必须两端同时改，并更新两端的 golden 测试（iOS：`WikiReaderTests/SharedCacheFormatTests.swift` + `WikiReaderTests/Fixtures/shared/`）。
> 目的：两端把 OpenAI 生成的音频存进同一个 Google Drive 目录，互相复用，同一段话只付一次费。
> 用户已同意：**共享格式以 iOS 现有格式为准**（iOS 端已有付费生成的音频，改格式会全部作废）。

## 1. 两端必须完全一致的东西

一个音频文件能被另一端找到，当且仅当下面四样逐字节相同：切出来的文本、模型、声音、风格说明（instructions）。

### 1.1 Key（文件名）

```
key = lowercase_hex( SHA-256( UTF-8( model + "\u001F" + voice + "\u001F" + instructions + "\u001F" + text ) ) )
文件名 = key + ".mp3"
```

- `\u001F` 是 ASCII 单元分隔符（0x1F），不是换行。
- instructions 为空时也要保留分隔符（`model␟voice␟␟text`）。
- 没有版本前缀、没有格式字段：格式固定 mp3（`response_format: "mp3"`）。
- 语速不参与（两端都用本地播放速率控制，不传给 OpenAI）。
- 代码：iOS `WikiReader/Services/OpenAI/SpeechAudioCache.swift` 的 `key(for:)`。

### 1.2 请求参数（iOS 现值）

| 字段 | 值 |
|---|---|
| model | `gpt-4o-mini-tts` |
| voice | 用户选的，默认 `marin`（iOS 提供 marin、cedar、alloy、ash、ballad、coral、echo、fable、nova、onyx、sage、shimmer、verse） |
| instructions | `Read like a clear, natural audiobook narrator, at a steady, moderate pace.`（固定，所有声音都带） |
| response_format | `mp3` |

两端默认声音和 instructions 不同的话，同一段文字的 key 也不同，等于不共享。

### 1.3 切块

- 单位是“内容块”：一个章节标题或一个正文段落各是一块。**标题也单独成块、单独生成音频**（朗读时读出标题）。
- 块的 UTF-16 长度 ≤ 4096：整块一个请求，`text` 就是块文本本身。绝大多数 Wikipedia 段落属于这种。
- 块 > 4096（UTF-16 单位）：iOS 用 Apple `NLTokenizer(unit: .sentence)` 找句末，在 ≤4096 的范围内取最后一个句末切开；没有句末就退到最后一个空白之后；再没有就硬切在 4096。循环直到剩余 ≤4096。代码：`SpeechChunking.chunks(of:)`。
  - 这一条 Chrome 很难逐字节复现（NLTokenizer 是 Apple 的分句器）。这种超长段落在 Wikipedia 很少见，可以接受“这些段落两端各自生成、不共享”，或者另定一个两端都能实现的规则（但会让 iOS 已有的这部分音频作废，代价很小）。**请评估。**

### 1.4 文本来源（最关键）

key 里的 `text` 是 iOS 清洗后的块文本。Chrome 只有抽出**完全相同**的文本，才能命中 iOS 生成的音频（反之亦然）。iOS 的抽取方式：

- 请求 `https://en.wikipedia.org/w/api.php?action=parse&prop=text&redirects=1&disableeditsection=1&disablelimitreport=1&disabletoc=1&format=json&formatversion=2&page=<标题>`
- 解析 HTML：只取 `<h2>`–`<h6>`、段落、列表项；跳过表格、信息框、导航框、图注、引语框、hatnote（“Main article:”）、脚注上标、公式；嵌入的“摘录”段落保留。
- 清洗：删除 See also / References / Notes / Footnotes / Citations / Sources / Bibliography / Works cited / Further reading / External links 章节及其子章节；去掉首段发音信息和留下的空括号；去掉 `{\displaystyle` 残留和引用标记；合并空白。
- 代码：`Services/ArticleHTMLParser.swift`、`Services/ArticleCleaner.swift`；测试样本 `WikiReaderTests/Fixtures/`（albert_einstein、paris、pythagorean_theorem、excerpt_section 的真实 API 返回）。

建议 Chrome 对 Wikipedia 也走同一个 `action=parse` 接口，并把上面两个文件的规则移植过去，用同一批 fixture 做对照测试（iOS 可以导出每个 fixture 的块文本作为期望值）。用 Readability 抽 DOM 的话，空白、引号、被删掉的元素都可能不同，命中率会很低。非 Wikipedia 网站 iOS 不支持，Chrome 用什么规则都不影响共享。

## 2. 对照用的测试向量

（iOS 单元测试 `WikiReaderTests/SharedCacheFormatTests.swift` 里同样的数据；Swift CryptoKit 与 Python hashlib 结果一致）

| voice | text | key |
|---|---|---|
| marin | `History` | `c38d77d2cd3a52901c7456918124df580153bd59e6dad5b0f7750cf38d469c99` |
| marin | `Paris is the capital and largest city of France.` | `52d523be04f1e95b54b6ffdf47139a1dcbb626fd25f3a3895047693fa5591df7` |
| marin | `Café “Le Procope” — founded 1686, it’s Paris’s oldest café.` | `c46c86aa2c932c0a4a2b5c85b8ac30f344408fbdb9cd4ea4e71b8fb878eb124c` |
| alloy | `History` | `6ad6857debc4cd97e362ae44631e2564a9d817d230b62fea2eccc40b69705fbd` |

model 和 instructions 都是 §1.2 的值。

## 2.1 Fixture 的块文本与 key

`WikiReaderTests/Fixtures/shared/<fixture>.blocks.json`：albert_einstein、paris、pythagorean_theorem、excerpt_section 四个真实 API 返回经 iOS 清洗后的每一块（kind、level、text）、切出的请求文本和 marin 声音下的 key，以及文章的 url / urlHash。iOS 测试每次都核对；Chrome 端已对照这 4 个 fixture（656 块）和另外 5 篇实时文章，逐字节一致。

## 2.2 文章 URL 与 urlHash

- `url = "https://en.wikipedia.org/wiki/" + parse.title`（重定向后的正式标题），空格换成 `_`，编码与 Foundation `URLComponents.path` 相同：RFC 3986 pchar（unreserved、sub-delims `!$&'()*+,;=`、`:`、`@`）和 `/` 原样保留，其余字符按 UTF-8 编成 `%XX`（大写十六进制）。
- `urlHash = lowercase_hex(SHA-256(UTF-8(url)))`。
- 向量：`WikiReaderTests/Fixtures/shared/url_hash.json`（含 hash），Chrome 仓库 `tests/fixtures/wikipedia/url-vectors.tsv`。例：`C++` → `C++`，`Café` → `Caf%C3%A9`，`What? (film)` → `What%3F_(film)`，`100% (song)` → `100%25_(song)`，`Hello#x` → `Hello%23x`。

## 3. Drive 目录（沿用 Chrome SPEC §7.3）

```
WikiReader Cache/
├── format.json          { "formatVersion": 1, "key": "ios-v1" }   ← 建议加 key 字段标明算法
├── audio/<key>.mp3
└── articles/<urlHash>.json
```

- scope 仅 `drive.file`；iOS 的 OAuth Client 建在 Chrome 用的同一个 Google Cloud 项目里。
- `format.json` 内容：`{"formatVersion":1,"key":"ios-v1"}`。
- 文章清单 `articles/<urlHash>.json` 沿用 Chrome SPEC 的结构：`chunker` 为 `"ios-paragraph-4096"`；`chunks[]` 每项 `{ i, p, text, key }`，`p` 是块序号，可选 `kind`（`"heading"`/`"paragraph"`）和 `level`（标题后停顿用，读取时可缺省）；`instructions` 用 §1.2 的值；`updatedBy` 为 `"ios"` 或 `"chrome"`。
- **清单要列出全文所有块**（包括还没有音频的块），`complete` 表示所有块的音频都已在 Drive 上。
- **清单优先**：Drive 上已有某篇的清单，且 model、voice、instructions 与当前设置相同，就直接用清单里的块文本和 key，不重新抽取。所以任何一端上传音频时都要写或更新清单。
- 两端同时上传同一段造成重名文件时，读取方任取一个。
- urlHash 见 §2.2。

## 4. 其他约定

- 超长段落（>4096 UTF-16）：不强求一致。iOS 用 NLTokenizer，Chrome 用近似规则（句末连同其后的空白一起切，片段不 trim），碰巧相同就能命中。实测 4 个长 fixture 里最长段落只有 1702 字符。
- Chrome 在浏览器里不能改 User-Agent，访问 Wikipedia 用 `Api-User-Agent: WikiReader-Chrome/0.1 (personal browser extension)`。
- OAuth：GCP 项目按 Chrome 仓库 `docs/google-oauth-setup.md` 创建；iOS 的 OAuth Client 必须建在同一个项目里（`drive.file` 的可见范围按项目划分）。
- 非 Wikipedia 网站和 Chrome 的“只读选中文字”不共享。
