# English Reader 网站 ↔ iPhone WikiReader：接口与同步需求 v1

> 提出方：iOS WikiReader 的 Claude 会话，2026-11-05。站长（用户）决定由 iOS 端提要求、网站端实现。
> 权威版本在 iOS 仓库 `docs/site-api-for-ios.md`，网站项目里的 `docs/from-ios/` 是副本。
> 状态：**草案，等网站端实现和回复**。实现时如果要改字段或语义，写进 `docs/from-ios/REPLY.md`（见 §8），站长会转给 iOS 端。
> 同目录的附件：
> - `shared-tts-cache-format.md`：音频 key 公式（ios-v1）、切块、Wikipedia 文章 URL 规则
> - `shared-vocab-format.md`：生词本 v2 格式和合并规则
> - `vocab-vectors/`：生词本的 4 个测试向量（iOS 仓库 `WikiReaderTests/Fixtures/shared/vocab/`）
> - `tts-vectors/url_hash.json`：Wikipedia 文章 URL 和 urlHash 的向量（`shared-tts-cache-format.md` §2.2）
>
> 这两份格式文档在网站 CLAUDE.md 规则 2 里写的路径是 iOS 那台 Mac 上的，云主机上没有，以这里的副本为准。

## 0. 背景：iPhone 要做什么

站长决定把网站作为 iPhone App 的主要文章来源，手动添加文章的功能保留。iPhone 端会这样用网站：

1. **同步文章目录**：每篇已发布的文章在手机上建一条本地记录（只存元数据）。
2. **取正文**：文章被打开或加入书库时，再取这篇的正文。
3. **取音频**：朗读时从 R2 下载音频片段。片段的文件名就是 ios-v1 key，与 iPhone 本机的语音缓存同名，所以下载后直接放进缓存，播放、逐词高亮、离线收听都用现有代码。手机上已有的片段不重复下载，iPhone 端也不调用 OpenAI。
4. **生词本**：网站成为 Google Drive 上 `WikiReader Cache/vocab.json` 的第三个读写方（§5），和 iPhone、Chrome 插件三方同步。

**现状**（2026-11-05 在线上实测）：
- 网站没有 JSON 接口，`/api/...` 都返回 404。数据只存在于页面里 Next.js 内嵌的 RSC 数据中（`ReaderView` 的 props）。
- iOS **不解析** RSC 数据：那是框架的内部格式，Next.js 一升级或者 props 一改名，App 就会悄悄失效。
- 已验证：《The Paradox of Convenience》13 个片段的文件名全部等于 ios-v1 key，音频是 128 kbps。`src/server/audio.ts` 的 `PROFILE` 是 passthrough，也就是分发的就是原文件。

## 1. 总则

1. **前缀和访问**：新增只读接口，前缀 `/api/app/v1/`。公开访问，不用登录，**只返回已发布的内容**。数据来自发布快照（`article_releases`），草稿、预览、编辑中的工作副本、管理员字段都不能出现。
2. **JSON 规则**：
   - 编码 UTF-8；所有时间都是 Unix 毫秒整数。
   - 没有值的字段直接省略，不写 `null`。
   - iOS 忽略不认识的字段，所以**加字段不用通知 iOS**。
   - 改字段含义、删字段、改类型都算不兼容，要换成 `/api/app/v2/`，并且 v1 保留到 iOS 改完为止。
3. **缓存**：两个接口都返回 `ETag`，支持 `If-None-Match` 返回 304，另外设 `Cache-Control: no-cache`（可以缓存，但每次都要重新验证）。
4. **错误**：返回体是 `{"error":{"code":"not_found","message":"…"}}`，状态码照常：文章不存在或未发布返回 404，参数错误返回 400，限流返回 429 并带 `Retry-After`。
5. **iOS 怎么请求**：
   - 请求头带 `User-Agent: WikiReader/0.1 (iOS app)`（不带邮箱）和 `Accept: application/json`。
   - 同步目录的时机：App 回到前台时（同一台设备至少间隔 10 分钟）和下拉刷新时；取详情：打开或加入文章时。
   - 一个人用，一天几十个请求。如果设限流，按 IP 每分钟 120 次以上就够。
6. **`/api/app/*` 不能被 Cloudflare 的 Bot Fight Mode、JS 质询或 Turnstile 拦截**。App 不是浏览器，过不了质询，只会收到一个 HTML 页面，而不是 JSON。
7. 不需要 CORS，因为调用方不是网页。

## 2. 文章目录：`GET /api/app/v1/articles`

增量同步：按全站的"变更序号"（seq）翻页。

| 参数 | 说明 |
|---|---|
| `since` | 上次同步拿到的 `latest`（整数）。第一次同步或要全量时，省略或传 `0` |
| `limit` | 每页条数，默认 200，最大 500 |

响应：

```jsonc
{
  "formatVersion": 1,
  "epoch": "k3v9q2",          // §2.2：数据库恢复后会换
  "maxSeq": 1240,             // 当前全站最大的 seq
  "latest": 1234,             // 本页最后一条的 seq；本页为空时等于请求里的 since
  "hasMore": false,           // true 时客户端用 since=latest 继续取
  "items": [ /* 按 seq 升序，见下 */ ]
}
```

**已发布的文章**：

```jsonc
{
  "id": "6f1c…",                      // 文章 UUID（articles.id），永远不变。iOS 用它作本地主键
  "seq": 1230,
  "slug": "united-states",            // 可能会变
  "pageUrl": "https://english.thrones.wang/a/united-states",
  "canonicalUrl": "https://en.wikipedia.org/wiki/United_States",   // §2.1
  "title": "United States",
  "excerpt": "It is a federal republic consisting of 50 states…",  // 纯文本，最多约 300 字符
  "category": { "id": 3, "name": "Places" },                       // 可选
  "tags": ["…"],                                                   // 可选
  "cefr": "C1",                                                    // 可选
  "wordCount": 14404,
  "source": {
    "kind": "wikipedia",              // wikipedia | web | original | upload（即 articles.source_type）
    "url": "https://en.wikipedia.org/wiki/United_States",          // wikipedia 和 web 必填；original、upload 省略
    "host": "en.wikipedia.org",       // 仅 wikipedia
    "revision": 1383024789            // 仅 wikipedia，可选
  },
  "license": "CC-BY-SA-4.0",
  "publishedAt": 1793750000000,       // 第一次发布的时间
  "releasedAt": 1793790000000,        // 当前这个发布版本的时间（"发布更新"后会变）
  "contentVersion": "9c0e4a1f2b3d5e6f",   // §3.4
  "audio": {
    "voice": "alloy",
    "totalChunks": 191,
    "readyChunks": 191,               // R2 上已经有文件的片段数
    "readyMs": 6081528                // 已就绪片段的总时长
  }
}
```

`narration` 选了 `none`（这篇不配 AI 音频）的文章省略 `audio`，iPhone 会用系统声音朗读。

**已下架或已删除的文章**：

```jsonc
{ "id": "6f1c…", "seq": 1234, "removed": true }
```

下架后重新发布的文章，会以新的 seq、按普通文章再出现一次。

### 2.1 canonicalUrl（各端用来认"同一篇文章"）

- **Wikipedia 文章**：等于 `source.url`，就是 `shared-tts-cache-format.md` §2.2 里的规范 URL。网站的 `articles.source_url` 和 `url_hash` 应该已经按这个规则算好。
  - iPhone 用它认出手机上已经从 Wikipedia 直接添加过的同一篇，不会重复建记录，已下载的音频也能继续用。
  - 生词本原句的 `url` 也用它。
  - 其他 Wikipedia 站点（比如 simple.wikipedia.org）用同样的规则，只换 host。
- **其他文章**：等于 `pageUrl`。slug 改了以后，旧的 `/a/<旧 slug>` 要**永久重定向**到新地址，因为生词本原句里存的还是旧 URL。

### 2.2 seq 的规则（最关键的一条）

- **计数器**：全站共用一个单调递增的整数计数器。凡是接口里能看到的变化，都要在**同一个写事务里**给这篇文章分配一个新 seq（计数器加一）。包括：
  - 目录字段变了；
  - 发布或发布更新；
  - 有新的音频片段就绪；
  - 下架、删除；
  - 分类改名（改名后，该分类下的每篇文章都要拿到新 seq）。

  SQLite 的写事务是串行的，所以提交顺序和 seq 顺序一致，客户端翻页时不会漏掉变化。
- **不能用时间戳代替 seq**：两次写入在同一毫秒、时钟回拨，或者事务里先取时间再提交，都会让客户端漏掉变化。
- **墓碑**：下架或删除的文章要留一条墓碑（id 加 seq），永久保留，体积很小。
- **epoch**：数据库从备份恢复后，seq 会倒退。恢复流程里要换一个新的 epoch，这一步请写进 `docs/deploy.md` 的恢复步骤。客户端只要发现 epoch 变了，或者自己存的 `since` 比 `maxSeq` 还大，就从 0 开始全量重新同步。
- **音频生成时可以合并**：worker 生成音频时，不必每个片段都换一次 seq，可以一批换一次，比如一篇完成时，或者每 30 秒一次。

## 3. 文章详情：`GET /api/app/v1/articles/{id}`

```jsonc
{
  "formatVersion": 1,
  // ……这里是 §2 目录条目的所有字段，取值与这一刻一致……
  "attribution": {
    "text": "Source: “United States” on Wikipedia, by Wikipedia contributors, revision 1383024789 (2026-10-31). Licensed under CC BY-SA 4.0. …",
    "parts": [ { "text": "Source: “" }, { "text": "United States", "href": "https://en.wikipedia.org/wiki/United_States" }, … ]
  },
  "narration": {
    "key": "ios-v1",
    "model": "gpt-4o-mini-tts",
    "voice": "alloy",
    "instructions": "Read like a clear, natural audiobook narrator, at a steady, moderate pace.",
    "chunker": "ios-paragraph-4096",
    "profile": "mp3-128k",
    "sourceIdentical": true              // §4.2
  },
  "blocks": [
    { "kind": "heading", "level": 2, "text": "History", "readable": true,
      "chunks": [ { "key": "6ad6…", "off": 0, "text": "History",
                    "url": "https://audio.thrones.wang/audio/mp3-128k/6ad6….mp3", "ms": 1150 } ] },
    { "kind": "paragraph", "level": 0, "text": "…", "readable": true, "chunks": [ … ] },
    { "kind": "figure", "readable": false,
      "figure": { "src": "https://audio.thrones.wang/img/….webp", "src600": "https://audio.thrones.wang/img/…-600.webp",
                  "width": 960, "height": 630, "alt": "", "caption": "纯文本图注（不带 HTML）",
                  "credit": "…", "license": "CC-BY-SA-4.0", "sourceUrl": "…" } },
    { "kind": "table", "readable": false, "html": "<table>…</table>" }
  ]
}
```

没有 AI 音频的文章（`narration` 选了 `none`）省略整个 `narration` 字段，各个块也不带 `chunks`。

### 3.1 可朗读块（iPhone 第一期只用这些）

- `blocks` 按阅读顺序包含所有块。iOS 第一期只显示 `readable: true` 的块：`kind: "heading"` 显示为标题，其余可朗读的块（段落、列表项、引用……）都按段落显示。
- **`text` 必须和生成音频时用的文本逐字相同**，也就是 key 里的那段文本。Wikipedia 文章的文本与 iOS 清洗规则的输出逐字相同，网站 CLAUDE.md 规则 4 已经保证了这一点。
- `level`：标题是 2–6（wikitext 的 `==` 对应 2），段落是 0。这和 iOS 的 `ContentBlock` 一致，也和网站现在的数据一致。
- `chunks`：
  - 按 `chunker` 切出的每一片都要列出，**包括还没有音频的片段**（这种片段省略 `url` 和 `ms`）。切法是：块长度不超过 4096 个 UTF-16 单位就整块一片；超长的按 iOS 规则切开。
  - `off` 是片段在块 `text` 里的起始位置，单位是 UTF-16（和 JS 字符串下标一样）。
  - `key` 按 ios-v1 公式计算。
- **iOS 会校验**：用 `narration` 里的 model、voice、instructions 和片段 `text` 重新算 key。对不上的片段不下载、不缓存，当作没有音频，用系统声音读。

### 3.2 不可朗读块（iOS 第一期不用，先给出来，以后显示插图要用）

- **figure**：图片地址（R2 上的公开地址）、宽高、alt、纯文本图注、署名、授权和来源链接（SPEC §8.7）。
- **table、infobox**：`html` 字段，内容是网站已经按白名单清理过的 HTML。iOS 以后可能用 WebView 显示，也可能不显示。

### 3.3 一致性

- 详情里的 `seq`、`contentVersion` 必须和同一次返回的内容对得上。seq 不变，详情内容就不变，所以 ETag 可以直接用 `seq` 或 `contentVersion`。

### 3.4 contentVersion

- 它是 iOS 关心的那部分内容的指纹，包括：所有块的 kind、level、text、readable，以及每个片段的 key 和"有没有 url"。
- 改了文字、某个片段新就绪了音频，指纹都会变；只改目录里的分类或难度，指纹不变。
- 建议取 SHA-256 的前 16 个十六进制字符。iOS 只比较是否相等，不解析里面的内容。
- iOS 发现目录条目的 `contentVersion` 和本地存的不同，就会重新取详情。

## 4. 音频文件（R2，`audio.thrones.wang`）

### 4.1 访问方式

- **地址**：片段 URL 一旦给出，地址和内容都不再变。现在的 `Cache-Control: public, max-age=31536000, immutable` 正合适。地址不带查询参数，与 WAF 规则一致。
- **请求方式**：支持 GET 和 Range（现在已支持）。
- **iOS 会怎么取**（供估算流量和 R2 的 Class B 操作次数）：
  - 播放时：当前片段，加上后面最多约 75 秒、最多 4 个片段；同时最多 2 个请求；跳段时重新计算。
  - 用户点"下载整篇"时：逐个取完全部片段，同时 2 个请求。
  - 下载过的片段永久留在手机上，之后不再请求。
  - 超时、5xx、429 最多重试 3 次；429 按 `Retry-After` 等待。
- **实测发现的问题**（2026-11-05）：音频响应头是 `cf-cache-status: DYNAMIC`，也就是 Cloudflare 没有缓存音频，每次播放都直接打到 R2。站长一个人用无所谓，但网站的防刷方案依赖 Cloudflare 缓存，**建议检查**：R2 自定义域名需要配一条 Cache Rule，让 `/audio/*` 和 `/img/*` 设为 "Eligible for cache"。

### 4.2 R2 文件和 Drive 上源文件的关系（重要）

- iOS 把下载的片段存成 `<key>.mp3`，和自己用 OpenAI 生成的音频放在一起。用户在手机上手动"备份到 Drive"时，Drive 上缺的片段会被上传到 `WikiReader Cache/audio/<key>.mp3`。
- 所以 `narration.sourceIdentical: true` 表示 R2 上的文件和 OpenAI 返回的字节完全相同，也就是和 Drive 上的源文件一样。现在 passthrough，应该是 true。
- 如果以后分发版改成转码后的文件（比如 64k），必须**同时**做到两点：
  1. `profile` 换成新值，URL 路径也随之改变；
  2. `sourceIdentical` 设为 false。

  这样 iOS 照常播放，但会把这些文件单独存放，**不上传到 Drive**，避免用低码率文件冒充 ios-v1 的源文件。

## 5. 生词本：网站作为 Drive 上 `vocab.json` 的第三个读写方

### 5.1 为什么这么做

- iPhone 和 Chrome 已经通过 Drive 上的同一个文件同步，格式、合并规则和测试向量都定好了（附件 `shared-vocab-format.md`）。网站按同一套规则读写这个文件，三方自然就一致了，**iPhone 和 Chrome 都不用改**。
- "同一个用户"指的是同一个 Google 账号的 Drive。网站本来就用 Google 登录，连接 Drive 时用的也是这个账号。
- 没有选"iOS 直接调用网站的生词本接口"，原因有三个：
  - iOS 要新做一套登录和网站会话；
  - Chrome 也得跟着改；
  - 网站宕机时，三方都同步不了。
- 代价：网站要保存每个开启同步的用户的 Drive 授权（refresh token 加密保存，和现在站长连接 Drive 用同一套机制）。

### 5.2 要求

1. **格式和测试**：格式和合并规则完全按 `shared-vocab-format.md` v2（§2–§7）。用 `vocab-vectors/` 里的 4 个文件（normalize、term_key、match、merge）做测试，必须全部通过。网站的 `core/shared/vocabV2` 是从 Chrome 复制过来的，应该已经能通过；如果有出入，以这几份文件为准。
2. **开启同步**：
   - 在生词本页或账户页放一个开关，比如"Sync with the WikiReader app and Chrome extension"。用户打开时，网站增量申请 `drive.file` 授权。
   - Web OAuth Client 必须和 Chrome 插件、iOS 在**同一个 GCP 项目**里，否则看不到 `WikiReader Cache/`。
   - **账号不能混**：授权 Drive 的 Google 账号必须和登录账号一致，不一致就拒绝开启同步，并告诉用户原因。每个用户只读写自己 Drive 里的那份文件；同一个网站用户换了 Google 账号重新授权时，要先清掉旧账号的同步状态（文件 id、md5），不能把旧账号的词合并进新账号。iPhone 这一端也是这样做的：每本生词本绑定一个 Google 账号，换账号登录时把旧的单独存起来，换上新账号自己的那本。
3. **数据库就是"本机副本"**：网站数据库里某个用户的生词本，就相当于这个用户在网站这一端的本机副本（对应 iOS 的 `Vocabulary.json`）。
   - 要保存 v2 的全部字段，包括 `deleted` 墓碑。
   - **每一层不认识的字段都要原样保留**。现在的表结构有 `vocab_entries.ext`，但**原句这一层（`vocab_contexts`）和文件顶层还没有地方存**，需要加上。比如以后 Chrome 在原句里加了字段，经过网站合并一次就会丢掉。
   - 网站上点 "Got it" 或删除，就是 `deleted[key] = 现在`（§5）。撤销就是重新收藏：新的 `updatedAt` 比墓碑新，词条自然恢复。
   - 网站自己专用的数据放在词条的 `"web": { }` 里，和 `chrome`、`ios` 一样，其他两端会原样保留。
4. **`updatedBy` 写 `"web"`**。
5. **收藏时的 term 和 key**：按 §3.1 的规则，和 Chrome 一样跳过 NLTagger 那一步。
6. **原句的 `url` 和 `title`**：`url` 用 §2.1 的 canonicalUrl（Wikipedia 文章是 Wikipedia 的 URL，其他文章是 `https://english.thrones.wang/a/<slug>`），`title` 用文章标题。
7. **同步流程**按 §7 来，包括"`md5Checksum` 没变就不下载"那一步。
8. **同步时机**：
   - 用户在网站上收藏、删除或加释义之后约 5 秒，多次操作合并成一次；
   - 打开开关时；
   - 打开生词本页时；
   - 打开阅读页时，如果距上次同步已超过 2 分钟，就在后台同步一次；
   - 可选：worker 每 15–30 分钟给最近活跃、开了同步的用户同步一次。
9. **状态显示**：在生词本页显示同步状态，和 iOS 一样分四种：已同步、正在同步、等 Chrome 转换旧格式（v1）、失败（附原因）。
10. **配额**：每次同步 1–3 个 Drive 请求。用户少，不会碰到配额。

### 5.3 和 iPhone 的关系

- 网站不需要、也不会主动访问 iPhone。iPhone 每次启动或回到前台，都会从 Drive 拉下完整的 `vocab.json` 合并（其中有网站推上去的词和删除记录）；在 iPhone 上删词，约 5 秒后连同删除记录推到 Drive，网站下次同步时就会读到。
- iPhone 不访问网站的生词本接口，只通过 Drive 上的文件同步。
- 所以网站上加的词，要等网站把它同步到 Drive、iPhone 再同步一次之后才会出现在手机上。iPhone 的同步时机是：App 回到前台时，以及收藏或删除词后约 5 秒。

## 6. 以后可能要的（现在不用做）

- 阅读进度同步，记录手机和网站各听到哪里（网站已有 `reading_progress` 表）。
- 在 iOS 上显示插图和表格（§3.2 已经给出了数据）。
- 段落翻译：网站有共享的 AI 段落翻译（`translations` 表）。以后可以在详情里给出，iOS 的翻译面板就能直接用，不用再花钱。

## 7. 网站自测清单

1. **目录同步**：
   - `since=0` 能拿到全部已发布文章，草稿永远不出现；
   - 发布、发布更新、生成新片段、下架、删除之后，用上次的 `latest` 去取，只拿到变化的那几条；
   - 下架和删除的文章以 `removed` 墓碑出现。
2. **片段**：每个片段用 `narration` 里的参数重算 key 都对得上；还没有音频的片段也列了出来。
3. **Wikipedia URL**：`canonicalUrl` 与 `shared-tts-cache-format.md` §2.2 的向量一致，比如 United States 的 urlHash 是 `29cfb0d6…`，和 Drive 上的清单相同。
4. **304**：带 `If-None-Match` 再请求一次，返回 304。
5. **不被拦截**：用 `curl -A "WikiReader/0.1 (iOS app)"` 从服务器以外的机器请求，拿到的是 JSON，没有被 Cloudflare 质询拦下。
6. **生词本**：
   - 4 个向量文件全部通过；
   - 三层不认识的字段往返一次都不丢；
   - 在网站上删一个词，iPhone 同步之后这个词也消失；
   - 在 iPhone 上加一个词，网站同步之后能看到。

## 8. 网站回复

做完后，在 `docs/from-ios/REPLY.md` 里写下：
1. 接口上线的地址；
2. 和本文不同的地方，以及原因；
3. `sourceIdentical` 的确认结果；
4. 生词本同步做到了哪一步。

站长会转给 iOS 端，iOS 端会用 curl 抓线上返回的数据存成测试 fixture，然后开始接入。

## 9. 增补（2026-11-05 晚，网站已上线 v1 之后）

iPhone 已接入 v1：书库有 English Reader 一栏，按分类展示（分类封面由 App 自己画），点开文章、朗读、整篇免费下载都已经做完。为了文章和分类变多以后更好用，再提两项。**都只加字段或接口，不改现有字段**，所以还是 v1，iPhone 已经按下面的格式写好代码：网站加上以后自动生效，没加也不影响。

### 9.1 文章封面 `cover`（目录条目和详情里都加，可选）

文章变多以后，同一分类的卡片都用分类配色，看起来一样。请给每篇文章一张封面小图：

```jsonc
"cover": {
  "src": "https://audio.thrones.wang/img/<sha>.webp",       // 大图（现有的 1200px 版本）
  "src600": "https://audio.thrones.wang/img/<sha>-600.webp", // 小图，列表里用这个
  "width": 960, "height": 630,
  "alt": "…",                                                // 可选
  "credit": "…",                                             // 可选，图片作者，属性页里显示
  "license": "CC BY-SA 4.0"                                  // 可选，图片授权，属性页里显示
}
```

- 选哪张：站长手动指定的优先；没指定就用正文第一张**授权可用**的插图（SPEC §8.7）；都没有就**省略** `cover`（iPhone 退回分类配色）。
- 地址必须是 R2 上公开、不带查询参数的 `/img/` 路径（和现在插图一样）。iPhone 在列表里只取 `src600`。
- 换了封面要分配新 seq（这是目录里看得到的变化，§2.2）。

### 9.2 分类列表 `GET /api/app/v1/categories`（可选，不急）

```jsonc
{
  "formatVersion": 1,
  "categories": [
    { "id": 2, "slug": "places", "name": "Places", "description": "Countries, cities and the people who live there.", "sort": 1, "articleCount": 12 }
  ]
}
```

- 只列至少有一篇已发布文章的分类；`articleCount` 只数已发布的。
- `sort` 是站长希望的顺序，小的在前。有了它，iPhone 的分类封面按这个顺序排；没有就按文章数从多到少。
- `description` 显示在分类页顶部的横幅里。
- 带 ETag，和其他接口一样。

### 9.3 回复

做完任意一项，在 `docs/from-ios/REPLY.md` 末尾加一节说明即可。

