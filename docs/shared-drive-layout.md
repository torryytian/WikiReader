# 统一的 Google Drive 数据规范 v2

> 状态：**已定稿 v2.4（2026-11-05）**，iOS 和插件的评审、站长的全部决定都已并入（见文末「修订记录」）。**权威版本是网站仓库的 `docs/shared-storage/drive-layout-v2.md`**（站长：数据以网站为准，规范也由网站维护），iOS 仓库的 `docs/shared-drive-layout.md` 和插件照抄；要改规范，先改网站这份，再同步给两端。网站端 Claude 起草。站长已定：**唯一的根目录叫 `English Reader`**，就用网站现在已经整理好的目录结构，三端都往这里收。
> 起因：站长希望网站、iPhone、Chrome 插件是同一个项目的三个客户端，**用同一份数据源**；Drive 上的数据要能做持久化：任何一端（包括网站的服务器）没了，都能从 Drive 恢复。
> 现行规范 `shared-tts-cache-format.md`（ios-v1）、`shared-vocab-format.md`（v2）里的**算法全部不变**：音频 key、切块、正文清洗、URL 规范化、生词格式都照旧，已经付费生成的音频一个都不作废。本提案只改"文件放在哪、文章清单里多写什么"。

## 0. 原则：以网站为准（站长 2026-11-05）

- **只有一个数据源**：Drive 上的 `English Reader/`，由网站负责维护：建目录、写 `README.md` 和 `format.json`、做迁移、定规范。
- iPhone 和插件可以改自己的逻辑和代码，但最终都按这份规范读写 `English Reader/`，**不另建平行的存储**。
- 网站的文章、分类、授权、插图、录音以网站为准。iPhone、插件生成的 AI 朗读原文件、Wikipedia 清单、生词本按本规范写进同一个地方，三端共用。
- **备份只由网站做**（数据库快照在 `backups/`）。iPhone 和插件不往 Drive 写备份。

## 1. 现在的问题

Drive 根目录下现在有三处数据，各管各的：

| 现在的位置 | 谁写 | 内容 |
|---|---|---|
| `English Reader/` | 网站 | 数据库备份、上传录音的原文件、插图、每篇网站文章的 JSON、说明和恢复脚本（2026-11-05 整理好） |
| `WikiReader Cache/` | iOS、插件、网站 | AI 朗读原文件 `audio/`、Wikipedia 文章清单 `articles/`、生词本 `vocab.json` |
| `WikiReader-<日期>.wikireader`（根目录） | iOS | iPhone 自己的数据备份 |

问题：同一类数据分在两处（AI 朗读和录音、网站文章和 Wikipedia 清单）；只有网站的数据能完整恢复；`WikiReader Cache` 名字叫"缓存"，实际是唯一的原始数据（花钱生成的音频）。

## 2. v2 目录结构

**就是网站现在的 `English Reader/`，再把 `WikiReader Cache` 的内容收进来**（标 ★ 的是要新收进来的，其余现在就是这样）：

```
English Reader/                          ← 三端唯一的根目录（同名多个时用最早创建的）
├── README.md                            人能读懂的说明（网站自动维护）
├── format.json                        ★ {"formatVersion": 2, "key": "ios-v1", "layout": "english-reader-drive/2"}（第 3 阶段最后才写；WikiReader Cache/format.json 那时改成带 movedTo 的 v2）
├── audio/<key>.mp3                    ★ AI 朗读的 128k 原文件（WikiReader Cache/audio/ 这个文件夹整个移过来）
├── recordings/<key>.mp3                 上传录音的 128k 原文件
├── articles/<名字>.json                 每篇文章一份清单（格式见 §3）；★ 和 WikiReader Cache/articles/ 合并成一个文件夹
├── images/<sha256>.webp                 文章插图（1200px WebP）
├── vocab.json                         ★ 生词本（由 WikiReader Cache/ 搬来，格式不变）
├── backups/                             网站数据库备份，只有网站写，文件名就是北京时间：
│   └── db_2026-11-05_18-58_UTC+8.db.gz
└── restore/                             网站的恢复脚本和说明
```

规则：
- **`audio/` 和 `recordings/` 只放 128k 原始音频，永远不压缩、不删除。**
  - 文件名都是 `<key>.mp3`，key 按 ios-v1 公式算。
  - 录音的 model 是 `upload`，voice 是 `rec-<录音 sha256 前 16 位>`，instructions 为空。
  - 分两个文件夹只是好分辨：AI 生成的、真人录的。两种 key 不会重复。找文件时先看 `audio/`，没有再看 `recordings/`。
  - 压缩版是各端自己的事（网站放 R2），不进 Drive。
- **`articles/`**：文件名就是查找依据，三端都只按文件名找：
  - **`<urlHash>.json`**：只用于「文本由 ios-v1 清洗器从这个 URL 原样抽出来」的清单（iPhone、插件读 Wikipedia 时写的，和现在一样）。
  - **`site-<uuid>.json`**：网站的文章，**包括来自 Wikipedia 的**。网站上的文字可能被站长编辑过，和清洗器抽出来的不一样，所以不能占用 `<urlHash>.json`，否则插件「清单优先」会读到和页面不一致的文字。网站清单里不写 `urlHash`，来源 URL 放在 `source.url`。
  - iPhone 的本机导入文章（URL 是 `wikireader-import://local/<uuid>`）照旧，只有 iPhone 用。
  - 好认：Drive 文件的「说明」（description）写标题，`properties`（公开属性，不用 `appProperties`）里写 `articleId`、`title`、`kind`（`wikipedia`/`web`/`upload`/`original`/`imported`，最后一个是 iPhone 的本机导入文章）。这些只是附加信息，**查找不依赖它们**。
  - 同一个文件名有多份时，取 `createdTime` 最早的，忽略 `"deleted": true` 的。
- **`images/`**：文件名是图片内容的 SHA-256，同一张图只存一份。
- **`backups/`**：只有网站写，文件名带北京时间（`db_2026-11-05_18-58_UTC+8.db.gz`），保留：最近 2 天每份、2 周每天一份、半年每月一份。**iPhone 和插件不往 Drive 写备份**（站长：网站把备份做好就够了）。
- 重名：同名多个时用最早创建的（沿用现有规则）。
- 删除：音频和图片永远不删。文章删除时，清单里写 `"deleted": true`，文件名前加 `deleted-`，不删文件。插件「已缓存」页现在的「删除」会永久删掉清单和没人引用的音频，第 2 阶段改成同样的软删除（**站长已确认**）。
- **位置**：`English Reader/` 在「我的云端硬盘」根目录。它本身、所有子文件夹、`format.json`、README 都必须由本项目的 OAuth 客户端通过 API 创建：在 Drive 网页里手动建的、或别的应用（rclone 等）传的，`drive.file` 权限下三端都看不到，会以为不存在、另建一个同名的。
- **用哪个根目录**（新客户端每次启动、iPhone 每次回到前台都重新判断，不永久缓存文件夹 ID）：
  - `English Reader/format.json` 是 v2，或 `WikiReader Cache/format.json` 写着 `movedTo` → 用 `English Reader/`；
  - 否则一律按旧方式：有 `WikiReader Cache/`（v1）就用它；没有就新建 `WikiReader Cache/` 和 v1 的 `format.json`。即使 `English Reader/` 已经存在（网站先建了它、但还没写 v2）也这样做。
  - **只有网站写 `English Reader/format.json` v2**（第 3 阶段最后一步），iPhone 和插件**绝不写 v2、也不新建 `English Reader/`**。理由：万一某次列文件夹时网络抖动、没列出 `WikiReader Cache/`，客户端自己写了 v2，三端就会提前切到空的新目录，然后重新付费生成。之后多出来的 `WikiReader Cache/` 由网站的补扫并过去。

## 3. 文章清单 v2（articles/*.json）

**沿用 `WikiReader Cache/articles/` 现在的 v1 字段，意义不变**，所以只认 v1 的客户端照样能读。v2 只增加字段。网站现在写的存档会按这个格式改写。

下面的例子是一篇来自 Wikipedia 的**网站文章**（`site-<uuid>.json`）；`<urlHash>.json` 的字段相同，只是 `url` 是抽取文本的那个 URL、`articleId` 是 urlHash，没有 `site`。

```jsonc
{
  // ── v1 原有（不变）──
  "formatVersion": 1,                 // 不变：v2 只加可选字段（向后兼容），版本号留给不兼容的改动
  "chunker": "ios-paragraph-4096",
  "url": "<网站上这篇文章的地址>",     // <urlHash>.json：抽取文本的那个 URL；网站文章：网站上的地址（来源 URL 在 source.url）
  "title": "COVID-19",
  "model": "gpt-4o-mini-tts", "voice": "alloy", "instructions": "…",
  "chunks": [ { "i": 0, "p": 0, "text": "…", "key": "…", "kind": "paragraph", "level": 0 } ],
  "complete": true,
  "updatedAt": "2026-11-05T10:58:00Z",
  "updatedBy": "web",                 // "ios" | "chrome" | "web"

  // ── v2 新增（都可选；读取方不认识就忽略，改写时原样保留）──
  "articleId": "site-<uuid>",         // = 文件名去掉 .json：<urlHash>.json 里是 urlHash，网站文章是 "site-<uuid>"
  "source": { "kind": "wikipedia", "url": "https://en.wikipedia.org/wiki/COVID-19", "host": "en.wikipedia.org", "revision": 1234567, "author": null },
  "license": "CC-BY-SA-4.0",          // 和 App 接口一样：SPDX 或网站内部 id
  "attribution": "Source: “COVID-19” on Wikipedia, by Wikipedia contributors, revision …",
  "blocks": [                         // 全文排版：标题、段落、列表、引用、插图……
    { "kind": "heading", "level": 2, "text": "Signs and symptoms", "readable": true },
    { "kind": "figure", "readable": false, "image": "images/<sha256>.webp", "caption": "…", "credit": "…", "license": "CC BY-SA 4.0" }
  ],
  "chunkExtras": { "<key>": { "ms": 41230, "wordStartsMs": [0, 320, 610] } },  // 时长、录音的词级时间
  "site": { "slug": "covid-19", "status": "published", "category": "Health", "cefr": "C2" },
  "deleted": false
}
```

- **谁写**：
  - 网站自己的文章只有网站写。
  - Wikipedia 清单（`<urlHash>.json`）谁生成了音频谁写。
  - 改写清单时，必须**先读、再改、再写**，保留自己不认识的字段。（现状：插件和 iPhone 都整份重写、不保留未知字段；第 2 阶段两端都改成保留。）
  - **一篇只有一份清单，不覆盖别的声音组合**：写之前先读已有的清单，它的 model、voice、instructions 和自己的不同，就**不写**；相同才改写，最后写的算。理由：清单里冻结的是生成音频那一刻的文字，Wikipedia 以后改了文章，插件和 iPhone 仍能靠它复用已付费的音频；被别的组合盖掉，改过的段落 key 就变了，要重新付费。读的一方发现清单里的声音组合和自己的不同，就自己抽文本、算 key。（v1 没有「不覆盖」这条，v2.3 起三端都遵守。）
  - 网站已经写过 4 份 `<urlHash>.json`（`updatedBy: "web"`：COVID-19、Cultural Revolution、Australia、United States），文字是清洗器原样抽出的，保留原名、不改名。站长编辑过的文章，网站不再更新它的 `<urlHash>.json`，编辑后的文字只写进 `site-<uuid>.json`。
  - 网站文章的 `blocks`、`chunkExtras` 要写全：网站没了的那天，iPhone 可以直接靠它们恢复文章。
- 有了 v2 清单，**插件也能读到网站上传的演讲**：文本在 `blocks`，音频在 `recordings/<key>.mp3`，跟读高亮用 `chunkExtras` 里的 `wordStartsMs`。iPhone 暂时仍从网站接口取网站文章和录音（不读 `recordings/`），见 §6。

## 4. 迁移步骤（不会中途坏掉）

| 阶段 | 谁做 | 内容 | 对其他端的影响 |
|---|---|---|---|
| 0（已完成） | 网站 | 网站自己的数据整理进 `English Reader/` | 无 |
| 1 | 网站 | 网站自己的文章存档改成 §3 的格式和命名（一律 `site-<uuid>.json`，说明里写标题，`properties` 写附加信息），仍放在 `English Reader/articles/`。**不往 `WikiReader Cache/articles/` 里补字段**：插件和 iPhone 现在每次整份重写清单，补进去的字段会被抹掉，这一步推到第 3 阶段 | 无 |
| 2 | iOS、插件 | ① 按 §2「用哪个根目录」判断，每次启动 / 回到前台都重新判断；② **只要 `WikiReader Cache/` 还在，查找时新旧两处都查**，一条查询即可：`('<新audio>' in parents or '<recordings>' in parents or '<旧audio>' in parents) and (name='k1.mp3' or …)`；写入只写当前根目录；③ 清单按文件名找，先读再改再写，保留未知字段，声音组合不同就不写（§3）；（iOS）网站来的文章不写 `<urlHash>.json`（现在网站还没有音频的网站文章用 OpenAI 声音读时会按它的 `canonicalUrl` 写一份，第 2 阶段停掉；手机上还没装过带网站的版本，实际没发生过）；④（插件）删除改成软删除；⑤ `vocab.json` 优先新位置，发现新旧两份就按 v2 规则合并；⑥ 认 `WikiReader Cache/format.json` 里的 `movedTo`；⑦（插件）设置页「诊断」显示插件版本和 Drive 数据格式 | 发版即可，旧版本照常工作 |
| 3 | 网站，在两端新版都装到站长所有设备（每台电脑的插件版本在插件设置页「诊断」里看）、站长确认、且手机没在用 OpenAI 生成朗读时 | **搬文件夹，不搬文件**（只改 parent，ID 不变）：① 把 `WikiReader Cache/audio` 这个文件夹**整个**移进 `English Reader/`，成为 `English Reader/audio/`。不能逐个移文件：iPhone 的音频索引只看新创建的文件，移进它已索引过的文件夹的文件永远看不到，会以为没有、重新付费生成；② 把 `WikiReader Cache/articles/*` 逐个移进 `English Reader/articles/`（目标文件夹已存在；iPhone、插件每次都重新列清单，没问题）；③ 两份 `vocab.json` 合并后写到 `English Reader/vocab.json`；④ **最后**写 `English Reader/format.json` v2；⑤ `WikiReader Cache/` **先不删**，留着空文件夹，把它的 `format.json` 改成 `{"formatVersion":2,"key":"ios-v1","movedTo":"English Reader"}`：没升级的旧客户端遇到 v2 会明确报错、停用 Drive，而不会因为找不到文件夹另建一个、让数据分叉；新客户端看到 `movedTo` 就切过去；⑥ 搬完过几天，网站再扫一次 `WikiReader Cache/`：新出现的 `vocab.json` 合并过去，新出现的清单、音频移过去；⑦ 确认它一直是空的、所有设备都是新版以后，**删掉 `WikiReader Cache/`**（站长要求：搬完把没用的目录删掉；删之后即使还有漏升级的旧版 iPhone，它会新建空文件夹，补扫能发现） | 旧版 iPhone 下次启动时停用 Drive 并报错（显示 "The Drive folder holds a different cache format"，不会提示升级），不会分叉，但它缺的段会照常用 OpenAI 生成、花钱；搬的那一刻正开着的旧版 iPhone 会一直用内存里的旧文件夹 ID，直到下次启动。**旧版插件拦不住**：它只在第一次连接时读 format.json，之后一直用存下的文件夹 ID，会继续往旧的 `articles/` 和 `vocab.json` 写（音频文件夹是整个移走的、ID 不变，它写的音频反而落在新位置）。所以必须先把所有设备升级，⑥ 的补扫收拾漏网的 |
| 4 | 站长 | 根目录下的 `WikiReader-<日期>.wikireader` 是以前在 iPhone 上手动导出、经 Google Drive App 存进去的，本项目的 OAuth 客户端看不到、也删不了（`drive.file` 权限）。不再需要的话，站长在 Drive 网页里手动删掉 | 无 |

## 5. 不变的东西

- 音频 key 公式、切块、正文清洗、URL 规范化（ios-v1）：一个字都不改。
- 生词本格式（shared-vocab-format v2）和合并规则；只是 `vocab.json` 换了文件夹。
- `WikiReader Cache/format.json` 在第 3 阶段之前保持 `{"formatVersion":1,"key":"ios-v1"}`，第 3 阶段最后一步才改成带 `movedTo` 的 v2（目的就是让旧客户端拒绝使用，而不是另建文件夹）。
- OAuth：三端仍在同一个 Google Cloud 项目里，只用 `drive.file` 权限。这个权限只能看到同一项目建的文件，所以三端能互相看到，别的应用看不到。
- 网站给 iPhone 的 App 接口（`/api/app/v1/…`）照旧：iPhone 在线时仍从接口拿目录和压缩音频；Drive 是持久化和离线的来源。

## 6. 已定的事

1. **备份**（站长定）：只有网站做。iPhone 和插件都不往 Drive 写备份；iPhone 的「导出备份」手动功能照旧，但不自动上传。
2. **iPhone 离线读网站文章**（iOS 已答复）：暂时不从 Drive 读。接口加 R2 免费又快，打开过的文章已经存在本机，离线能读能听。网站没了那天再加「从 Drive 恢复网站文章」，所以网站清单的 `blocks`、`chunkExtras` 要写全。
3. **插件「删除」改成软删除**（站长定）：清单写 `"deleted": true`、文件名加 `deleted-`，音频不删。
4. **第 3 阶段**（站长定）：iPhone 和插件把逻辑都改好、装到所有设备后，网站把数据全部搬到 `English Reader/`，最后删掉没用的 `WikiReader Cache/`（按 §4 第 3 阶段的顺序：先搬、过几天补扫、确认为空再删）。
5. **何时开始第 2 阶段**：站长已同意 iPhone 和插件改逻辑和代码，两端可以开始做第 2 阶段，做完装好后通知网站。

## 修订记录

- **v2.1（2026-11-05，并入插件端评审）**：第 3 阶段改成整个文件夹搬（原来逐个搬文件，会让存了旧文件夹 ID 的插件一直查空文件夹，以为没有音频、重新付费生成）；第 2 阶段新旧两处同时查找；旧文件夹进回收站，不永久删除；第 1 阶段不再往 `WikiReader Cache/articles/` 补字段（会被整份重写抹掉）；清单 `formatVersion` 保持 1；有 URL 的文章一律 `<urlHash>.json`，网站自己的文章 `site-<uuid>.json`；用 `properties`，不用 `appProperties`；写明位置、由谁创建、新装时谁来建；`vocab.json` 两份合并；`WikiReader Cache/format.json` 永不改；插件「删除」改软删除、插件备份两条待站长定。
- **v2.2（2026-11-05，并入 iOS 端评审）**：`WikiReader Cache/` 搬空后不删，改成带 `movedTo` 的 v2 `format.json`（旧版 iPhone 找不到文件夹会另建一个，数据分叉）；`audio` 必须整个文件夹移动（iPhone 的音频索引是增量的）；网站文章（包括来自 Wikipedia 的）一律 `site-<uuid>.json`，不写 `urlHash`（文字可能编辑过，不能冒充清洗器抽出的清单）；查找只靠文件名；清单「一篇一份、最后写的算」；根目录判断规则写全；iPhone 不读 `recordings/`；iPhone 根目录的旧备份由站长手动处理。
- **v2.2 定稿（2026-11-05，iOS 确认时的文字修正，规则不变）**：§3 的例子改成一篇网站文章（原来 `url` 写的是 Wikipedia 地址、`articleId` 是 urlHash，和 `site-<uuid>.json` 的规则对不上），`source` 加上 `url`；`kind` 加 `imported`（iPhone 本机导入文章）；第 2 阶段③加 iOS 一条：网站来的文章不写 `<urlHash>.json`；第 3 阶段写明旧版 iPhone 的报错原文、不会提示升级、缺的段会付费生成。
- **v2.3（2026-11-05，插件端第二轮）**：§3 加「不覆盖别的声音组合的清单」（组合相同才改写，最后写的算），第 2 阶段③同步；§3 写明网站已写的 4 份 `<urlHash>.json` 保留原名，站长编辑后的文字只进 `site-<uuid>.json`；第 3 阶段写明旧版插件拦不住 `movedTo`（只在第一次连接时读 format.json），搬的那一刻正开着的旧版 iPhone 也要到下次启动才停，所以先在每台电脑确认插件版本，搬完过几天网站再补扫一次 `WikiReader Cache/`。
- **v2.4（2026-11-05，站长决定；同日补充插件端指出的情况）**：「用哪个根目录」改成只有网站写 v2 的 format.json，客户端看不到 v2 时一律按旧方式用或新建 `WikiReader Cache/`（含 `English Reader/` 已存在但没有 v2、`WikiReader Cache/` 也不存在的情况）；新增 §0「以网站为准」，权威版本改为网站仓库这份；备份只由网站做，iPhone 和插件不写 Drive 备份（去掉 `ios_`、`chrome_` 备份和 iOS 第 2 阶段的自动备份）；插件「删除」改软删除已确认；第 3 阶段搬完、补扫、确认为空后删掉 `WikiReader Cache/`；根目录的旧 `.wikireader` 由站长手动删；两端可以开始第 2 阶段。
