# 统一的 Google Drive 数据规范 v2

> 状态：**已定稿 v2.2（2026-11-05）**，iOS 和插件的评审都已并入（见文末「修订记录」）。权威版本是 iOS 仓库的 `docs/shared-drive-layout.md`，网站（`docs/shared-storage/drive-layout-v2.md`）和插件照抄；§6 第 2、4、5 条待站长定，定了再改这里。网站端 Claude 起草。站长已定：**唯一的根目录叫 `English Reader`**，就用网站现在已经整理好的目录结构，三端都往这里收。
> 起因：站长希望网站、iPhone、Chrome 插件是同一个项目的三个客户端，**用同一份数据源**；Drive 上的数据要能做持久化：任何一端（包括网站的服务器）没了，都能从 Drive 恢复。
> 现行规范 `shared-tts-cache-format.md`（ios-v1）、`shared-vocab-format.md`（v2）里的**算法全部不变**：音频 key、切块、正文清洗、URL 规范化、生词格式都照旧，已经付费生成的音频一个都不作废。本提案只改"文件放在哪、文章清单里多写什么"。
> 确认后，权威版本放进 iOS 仓库（和另外两份共享规范放在一起），网站和插件照抄。

## 1. 现在的问题

Drive 根目录下现在有三处数据，各管各的：

| 现在的位置 | 谁写 | 内容 |
|---|---|---|
| `English Reader/` | 网站 | 数据库备份、上传录音的原文件、插图、每篇网站文章的 JSON、说明和恢复脚本（2026-11-05 整理好） |
| `WikiReader Cache/` | iOS、插件、网站 | AI 朗读原文件 `audio/`、Wikipedia 文章清单 `articles/`、生词本 `vocab.json` |
| `WikiReader-<日期>.wikireader`（根目录） | iOS | iPhone 自己的数据备份 |

问题：同一类数据分在两处（AI 朗读和录音、网站文章和 Wikipedia 清单）；只有网站的数据能完整恢复；`WikiReader Cache` 名字叫"缓存"，实际是唯一的原始数据（花钱生成的音频）。

## 2. v2 目录结构

**就是网站现在的 `English Reader/`，再把 `WikiReader Cache` 的内容和 iPhone 的备份收进来**（标 ★ 的是要新收进来的，其余现在就是这样）：

```
English Reader/                          ← 三端唯一的根目录（同名多个时用最早创建的）
├── README.md                            人能读懂的说明（网站自动维护）
├── format.json                        ★ {"formatVersion": 2, "key": "ios-v1", "layout": "english-reader-drive/2"}（第 3 阶段最后才写；WikiReader Cache/format.json 那时改成带 movedTo 的 v2）
├── audio/<key>.mp3                    ★ AI 朗读的 128k 原文件（WikiReader Cache/audio/ 这个文件夹整个移过来）
├── recordings/<key>.mp3                 上传录音的 128k 原文件
├── articles/<名字>.json                 每篇文章一份清单（格式见 §3）；★ 和 WikiReader Cache/articles/ 合并成一个文件夹
├── images/<sha256>.webp                 文章插图（1200px WebP）
├── vocab.json                         ★ 生词本（由 WikiReader Cache/ 搬来，格式不变）
├── backups/                             各端的备份，文件名直接看得出时间：
│   ├── db_2026-11-05_18-58_UTC+8.db.gz        网站数据库（北京时间）
│   └── ★ ios_<时间>.wikireader                  iPhone 的备份（命名由 iOS 定，但要带时间）
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
- **`backups/`**：各端只写、只删自己前缀的文件（网站 `db_`，iPhone `ios_`，插件以后用 `chrome_`），文件名带时间和时区（`db_2026-11-05_18-58_UTC+8.db.gz`、`ios_2026-11-05_18-58_UTC+8.wikireader`），按时间保留：最近 2 天每份、2 周每天一份、半年每月一份。
- 重名：同名多个时用最早创建的（沿用现有规则）。
- 删除：音频和图片永远不删。文章删除时，清单里写 `"deleted": true`，文件名前加 `deleted-`，不删文件。插件「已缓存」页现在的「删除」会永久删掉清单和没人引用的音频，第 2 阶段改成同样的软删除（**站长待确认**）。
- **位置**：`English Reader/` 在「我的云端硬盘」根目录。它本身、所有子文件夹、`format.json`、README 都必须由本项目的 OAuth 客户端通过 API 创建：在 Drive 网页里手动建的、或别的应用（rclone 等）传的，`drive.file` 权限下三端都看不到，会以为不存在、另建一个同名的。
- **用哪个根目录**（新客户端每次启动、iPhone 每次回到前台都重新判断，不永久缓存文件夹 ID）：
  - `English Reader/format.json` 是 v2 → 用 `English Reader/`；
  - 否则有 `WikiReader Cache/`（format.json 是 v1）→ 继续用它，**自己不写 v2 的 format.json、不新建 `English Reader/`**（`English Reader/` 现在已存在但还没有 v2，就是这种情况）；
  - 两个都没有（新的 Google 账号）→ 建 `English Reader/` 和 v2 的 `format.json`；
  - `WikiReader Cache/format.json` 写着 `movedTo` → 用 `English Reader/`。

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
  - **一篇只有一份清单，最后写的算**：清单只是索引。读的一方发现清单里的声音组合和自己的不一样，就自己抽文本、算 key（v1 实际就是这样，并没有「不覆盖其他声音组合」的规则）。
  - 网站文章的 `blocks`、`chunkExtras` 要写全：网站没了的那天，iPhone 可以直接靠它们恢复文章。
- 有了 v2 清单，**插件也能读到网站上传的演讲**：文本在 `blocks`，音频在 `recordings/<key>.mp3`，跟读高亮用 `chunkExtras` 里的 `wordStartsMs`。iPhone 暂时仍从网站接口取网站文章和录音（不读 `recordings/`），见 §6。

## 4. 迁移步骤（不会中途坏掉）

| 阶段 | 谁做 | 内容 | 对其他端的影响 |
|---|---|---|---|
| 0（已完成） | 网站 | 网站自己的数据整理进 `English Reader/` | 无 |
| 1 | 网站 | 网站自己的文章存档改成 §3 的格式和命名（一律 `site-<uuid>.json`，说明里写标题，`properties` 写附加信息），仍放在 `English Reader/articles/`。**不往 `WikiReader Cache/articles/` 里补字段**：插件和 iPhone 现在每次整份重写清单，补进去的字段会被抹掉，这一步推到第 3 阶段 | 无 |
| 2 | iOS、插件 | ① 按 §2「用哪个根目录」判断，每次启动 / 回到前台都重新判断；② **只要 `WikiReader Cache/` 还在，查找时新旧两处都查**，一条查询即可：`('<新audio>' in parents or '<recordings>' in parents or '<旧audio>' in parents) and (name='k1.mp3' or …)`；写入只写当前根目录；③ 清单按文件名找，先读再改再写，保留未知字段；（iOS）网站来的文章不写 `<urlHash>.json`（现在网站还没有音频的网站文章用 OpenAI 声音读时会按它的 `canonicalUrl` 写一份，第 2 阶段停掉；手机上还没装过带网站的版本，实际没发生过）；④（插件）删除改成软删除；⑤ `vocab.json` 优先新位置，发现新旧两份就按 v2 规则合并；⑥（iOS）自动备份到 `English Reader/backups/ios_<时间>.wikireader`（不带音频，内容有变化时最多一天一份）和「从 Drive 恢复」入口；⑦ 认 `WikiReader Cache/format.json` 里的 `movedTo` | 发版即可，旧版本照常工作 |
| 3 | 网站，在两端新版都装到站长所有设备、站长确认、且手机没在用 OpenAI 生成朗读时 | **搬文件夹，不搬文件**（只改 parent，ID 不变）：① 把 `WikiReader Cache/audio` 这个文件夹**整个**移进 `English Reader/`，成为 `English Reader/audio/`。不能逐个移文件：iPhone 的音频索引只看新创建的文件，移进它已索引过的文件夹的文件永远看不到，会以为没有、重新付费生成；② 把 `WikiReader Cache/articles/*` 逐个移进 `English Reader/articles/`（目标文件夹已存在；iPhone、插件每次都重新列清单，没问题）；③ 两份 `vocab.json` 合并后写到 `English Reader/vocab.json`；④ **最后**写 `English Reader/format.json` v2；⑤ `WikiReader Cache/` **不删**，留着空文件夹，把它的 `format.json` 改成 `{"formatVersion":2,"key":"ios-v1","movedTo":"English Reader"}`：没升级的旧客户端遇到 v2 会明确报错、停用 Drive，而不会因为找不到文件夹另建一个、让数据分叉；新客户端看到 `movedTo` 就切过去 | 旧客户端停用 Drive 并报错（旧版 iPhone 显示 "The Drive folder holds a different cache format"，不会提示升级），不会分叉；但它缺的段会照常用 OpenAI 生成、花钱，所以必须先把所有设备升级 |
| 4 | 站长 | 根目录下的 `WikiReader-<日期>.wikireader` 是在 iPhone 上手动导出、经 Google Drive App 存进去的，本项目的 OAuth 客户端看不到、也挪不动（`drive.file` 权限）。站长愿意的话在 Drive 网页里手动拖进 `English Reader/backups/`，或者留着不管 | 无 |

## 5. 不变的东西

- 音频 key 公式、切块、正文清洗、URL 规范化（ios-v1）：一个字都不改。
- 生词本格式（shared-vocab-format v2）和合并规则；只是 `vocab.json` 换了文件夹。
- `WikiReader Cache/format.json` 在第 3 阶段之前保持 `{"formatVersion":1,"key":"ios-v1"}`，第 3 阶段最后一步才改成带 `movedTo` 的 v2（目的就是让旧客户端拒绝使用，而不是另建文件夹）。
- OAuth：三端仍在同一个 Google Cloud 项目里，只用 `drive.file` 权限。这个权限只能看到同一项目建的文件，所以三端能互相看到，别的应用看不到。
- 网站给 iPhone 的 App 接口（`/api/app/v1/…`）照旧：iPhone 在线时仍从接口拿目录和压缩音频；Drive 是持久化和离线的来源。

## 6. 已答复和待站长决定的

1. **iOS 的备份**（iOS 已答复）：`.wikireader` 是单文件归档，含文章、阅读位置、书签、每篇的生词、可跨设备的设置（不含 OpenAI Key）、整本生词本，可选带音频和翻译缓存。iOS 第 2 阶段做自动备份（§4 第 2 阶段 ⑥），命名和保留规则同网站。
2. **插件要不要备份**（**站长定**）：插件只在浏览器里的是设置、阅读位置、花费账本。插件端建议暂时不做；要做就是一个很小的 `backups/chrome_<时间>.json`，绝不包含 OpenAI API Key。
3. **iPhone 离线读网站文章**（iOS 已答复）：暂时不从 Drive 读。接口加 R2 免费又快，打开过的文章已经存在本机，离线能读能听。网站没了那天再加「从 Drive 恢复网站文章」，所以网站清单的 `blocks`、`chunkExtras` 要写全。
4. **插件「删除」改成软删除**（**站长定**）：现在插件「已缓存」页的「删除」会永久删掉清单和没人引用的音频，和「音频永不删除」冲突。建议改成软删除。
5. **何时做第 3 阶段**（**站长定**）：两端新版装到所有设备后，站长挑一个手机没在用 OpenAI 声音朗读的时间告诉网站。

## 修订记录

- **v2.1（2026-11-05，并入插件端评审）**：第 3 阶段改成整个文件夹搬（原来逐个搬文件，会让存了旧文件夹 ID 的插件一直查空文件夹，以为没有音频、重新付费生成）；第 2 阶段新旧两处同时查找；旧文件夹进回收站，不永久删除；第 1 阶段不再往 `WikiReader Cache/articles/` 补字段（会被整份重写抹掉）；清单 `formatVersion` 保持 1；有 URL 的文章一律 `<urlHash>.json`，网站自己的文章 `site-<uuid>.json`；用 `properties`，不用 `appProperties`；写明位置、由谁创建、新装时谁来建；`vocab.json` 两份合并；`WikiReader Cache/format.json` 永不改；插件「删除」改软删除、插件备份两条待站长定。
- **v2.2（2026-11-05，并入 iOS 端评审）**：`WikiReader Cache/` 搬空后不删，改成带 `movedTo` 的 v2 `format.json`（旧版 iPhone 找不到文件夹会另建一个，数据分叉）；`audio` 必须整个文件夹移动（iPhone 的音频索引是增量的）；网站文章（包括来自 Wikipedia 的）一律 `site-<uuid>.json`，不写 `urlHash`（文字可能编辑过，不能冒充清洗器抽出的清单）；查找只靠文件名；清单「一篇一份、最后写的算」；根目录判断规则写全；iPhone 不读 `recordings/`；iPhone 根目录的旧备份由站长手动处理。
- **v2.2 定稿（2026-11-05，iOS 确认时的文字修正，规则不变）**：§3 的例子改成一篇网站文章（原来 `url` 写的是 Wikipedia 地址、`articleId` 是 urlHash，和 `site-<uuid>.json` 的规则对不上），`source` 加上 `url`；`kind` 加 `imported`（iPhone 本机导入文章）；第 2 阶段③加 iOS 一条：网站来的文章不写 `<urlHash>.json`；第 3 阶段写明旧版 iPhone 的报错原文、不会提示升级、缺的段会付费生成。
