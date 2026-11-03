# 共享生词本格式 v2（iOS WikiReader ↔ Chrome 插件）

> 状态：**定稿 v2（2026-11-03）**，iOS 会话和 Chrome 会话（`/Users/bytedance/Desktop/claude/chrome_extension_reading`，提案原稿 `docs/vocab-sync-proposal.md`）已对齐，用户已同意。
> **本文件是权威定义**，Chrome 的 SPEC §6.4 只做摘要并引用这里。
> **改动规则**：任何一处要改，两端同时改，并同步更新共享测试向量（iOS：`WikiReaderTests/VocabFormatTests.swift` + `WikiReaderTests/Fixtures/shared/vocab/`；Chrome 复制到 `tests/fixtures/ios-shared/vocab/`）。
>
> 用户的决定（2026-11-03）：
> 1. 生词本是**全局一本**，两端数据和判断逻辑一致，不再按文章分别记录。
> 2. **在任何地方取消收藏 = 两端都删除这个词**。"已掌握"就是删除，不另设状态。
> 3. 阅读时**所有生词都高亮**；同一原形的其他变形（studies ↔ studied）用较淡的样式提示。

## 1. 位置与编码

- Google Drive：`WikiReader Cache/vocab.json`，与 `format.json` 同级（目录结构见 `shared-tts-cache-format.md`）。同名文件有多个时用 `createdTime` 最早的一个。
- UTF-8、紧凑 JSON（不缩进）。所有时间都是 **Unix 毫秒整数**（Swift 端不要用 `JSONEncoder` 的默认日期编码）。
- 读的时候，值为 `null` 的字段等同于没有这个字段；写的时候不写 `null`，没有就省略。
- iOS 本机副本：`Application Support/Vocabulary.json`，结构与本文件完全相同。Chrome 本机存在 IndexedDB，同步时按本格式进出。

## 2. 结构

```jsonc
{
  "formatVersion": 2,
  "updatedAt": 1793700000000,          // 写这个文件的时间
  "updatedBy": "ios",                  // "ios" | "chrome"，只用于排查
  "entries": [
    {
      "key": "studies",                // §3，词条主键
      "term": "Studies",               // 显示的词头（保留原文大小写）
      "lemma": "study",                // 可选，§4，只用于显示，判断时各端用本机 ECDICT 重新算
      "forms": ["Studies", "studies"], // 原文里见过的写法（去重，最多 20 个）
      "createdAt": 1793600000000,
      "updatedAt": 1793650000000,      // 词条任何变化（加原句、加释义、加写法）都要更新
      "meaning": "研究",                // 可选，一句话中文释义
      "contexts": [
        {
          "id": "b1946ac92492d234",    // §3.3
          "sentence": "Many studies have shown…",
          "url": "https://en.wikipedia.org/wiki/COVID-19",
          "title": "COVID-19",
          "savedAt": 1793600000000,
          "meaning": "研究（复数）"       // 可选，这句话里的意思
        }
      ],
      "chrome": { },                    // 可选，Chrome 专有（AI 解释、Wiktionary 释义等），iOS 原样保留
      "ios": { }                        // 可选，iOS 专有（目前没有），Chrome 原样保留
    }
  ],
  "deleted": { "foo": 1793690000000 }   // 被删除的词：key → 删除时间
}
```

| 字段 | 说明 |
|---|---|
| `contexts[].url` | 文章的规范化 URL，与音频缓存的文章 URL 相同（`shared-tts-cache-format.md` §文章 URL）。iOS 导入的本地文章是 `wikireader-import://local/<UUID>`：Chrome 只显示标题，不做链接。非 Wikipedia 网页用页面 URL（去掉 `#fragment`，host 小写）。 |
| `meaning` | iOS 的 AI 一句话释义写进那条原句的 `contexts[].meaning`，词条的 `meaning` 为空时也填上；Chrome 的 `meaningInContext` 同理。 |
| 不认识的字段 | 任何一层（顶层、词条、原句）都**原样保留**，合并规则见 §6。 |

## 3. "同一个词"：term、key、原句 id

### 3.1 term（与 iOS `DictionaryLookup` 完全一致）

对原文里的一个词 `word`（iOS 是点中的词，Chrome 是选中的文字）：

1. 候选依次为：`word`；去所有格后的 `base`；`base` 的小写；（仅 iOS）NLTagger 给出的原形及其小写。重复的跳过。
   - 去所有格：`word` 以 `'s`、`’s`、`'`、`’` 之一结尾（按这个顺序检查第一个匹配的），且 `word` 比这个后缀长，就去掉这个后缀。`Einstein's` → `Einstein`，`parents'` → `parents`。
2. 取第一个 **ECDICT 包含**的候选作为 `term`；都不包含就用 `word` 本身。
   - 包含：候选去掉首尾空白后转小写，等于 ECDICT 某一行的 `lower` 列。
3. Chrome 没有 NLTagger，跳过那一步。ECDICT 有 77 万词条（变形词基本都在），原词不在 ECDICT、原形却在的情况很少，这时两端可能得到不同的 key，变成两个词条，接受。
4. ECDICT 的变形词就是独立词条，所以 `studies` 的 term 是 `studies`，**不是** `study`。**不要拿原形当 key**：会错并 left→leave、better→good、found→find、saw→see。

### 3.2 key = normalize(term)

按顺序：

1. Unicode NFKC；
2. 删除 U+FEFF、U+200B；
3. **逐个码点**做默认小写，不按地区、不用上下文规则。土耳其语 `İ`（U+0130）→ `i̇`（U+0069 U+0307）；希腊语词尾 `Σ` → `σ`（JS 对整串 `toLowerCase()` 会按词尾规则变成 `ς`，所以 Chrome 用 `[...s].map(c => c.toLowerCase()).join('')`）；
4. 弯引号 `‘`（U+2018）、`’`（U+2019）、`ʼ`（U+02BC）换成 `'`；
5. 这些码点都换成空格：U+0009–000D、U+0020、U+0085、U+00A0、U+1680、U+2000–200A、U+2028、U+2029、U+202F、U+205F、U+3000（不用 JS `\s` 或 Swift `whitespacesAndNewlines`，两者范围不同）；
6. 去掉首尾空格，中间连续空格合成一个。

注：ECDICT 的 `lower` 列是 Python `str.lower()` 生成的（整串、带希腊语词尾规则），所以以 `Σ` 结尾的希腊词头永远对不上。英文生词碰不到，不特殊处理。

### 3.3 原句 id

- `normalizeSentence(s)` 是上面的 1、2、4、5、6 步，**不转小写**。
- `id` = `lowercase_hex(SHA-256(UTF-8(normalizeSentence(sentence))))` 的前 16 个字符。
- 同一句话在两端的原文常有差别（Chrome 网页里有 `[1]` 引用标号，iOS 的正文是清洗过的），会算出不同的 id、成为两条原句。这是允许的。

## 4. 原形、归组与匹配（高亮和"已在生词本"都按这个判断）

- `lemma(x)`：取 ECDICT 中 `lower` 等于 `normalize(x)` 的各行，按 `word` 列的二进制顺序排；第一个 `exchange` 里有 `0:` 项的行，它的 `0:` 值就是原形。没有这样的行就是 null。
  - `exchange` 形如 `p:went/d:gone/0:go/1:p`，按 `/` 分开，取以 `0:` 开头的那一项。
  - 例：`studies`→`study`，`left`→`leave`，`run`→`run`（ECDICT 里 run 也是 run 的过去分词），`study`→null。
- `group(x) = lemma(x) ?? normalize(x)`。
- 对原文里的一个词 `t`，令 `k = normalize(term(t))`：
  - **SAVED**（就是这个生词）：`k` 是某个词条的 `key`。
  - **RELATED**（同一原形的其他写法）：不是 SAVED，但 `group(k)` 等于某个词条的 `group(key)`。例：收藏了 `studies`，那么 `studied`、`study` 都是 RELATED。偶尔会误提示（收藏 `left` 时 `leaving` 也算），用户已接受。
  - 只看含字母的词，纯数字和标点不参与。
- 各端用法：iOS 阅读页 SAVED 用正常的高亮样式，RELATED 用较淡的样式。Chrome 查词卡片对 SAVED 显示"✓ 已在生词本"，对 RELATED 显示"相关词 X 已在生词本"。
- 词条里存的 `lemma` 只用于显示，判断一律用本机 ECDICT 重新算，两端算法相同，结果就相同。

## 5. 增删改（本机操作）

任何修改都把词条 `updatedAt` 设为当前时间。

- **收藏**：没有这个 key 的词条就新建（`createdAt` = `updatedAt` = 现在），有就加一条原句（id 相同则更新 `savedAt`）、把写法加进 `forms`。同时去掉本机 `deleted` 里这个 key。
- **取消收藏、从生词本删除、"已掌握"**：都是同一个操作，删掉词条，`deleted[key] = 现在`。
- **生成释义**：写原句的 `meaning`；词条 `meaning` 为空时一起填上。

## 6. 合并

输入：本机 `L`、Drive 上的 `R`（可能没有）、当前时间 `now`。输出 `M`。两端逐字实现；除了下面注明的平局情况，结果与参数顺序无关。

1. **墓碑**：`deleted` 取并集，同一 key 取较大的时间；`now - 时间 >= 365 天`（31,536,000,000 毫秒）的丢掉。
2. **词条**：按 `key` 取并集，同一 key 用 `mergeEntry`（下）。
3. 对每个词条：`deleted[key] >= updatedAt` 就删掉词条；否则如果 `deleted[key]` 存在（比词条旧），删掉这个墓碑（词条被重新收藏了）。
4. 顶层不认识的字段：取 `updatedAt` 较大的那个输入的；一样大就取 `L` 的。`M.formatVersion = 2`，`M.updatedAt = now`，`M.updatedBy` = 本端。
5. 写出顺序：词条按 `createdAt` 升序，再按 `key` 的码点顺序。顺序不影响含义（不能用 JS `localeCompare`）。

`mergeEntry(a, b)`：

1. 定"较新的一边"：`updatedAt` 大的；一样大就比 `meaning`（没有算空串）的码点顺序，大的算较新；再一样就比 `term`；再一样取 `a`（这时两边内容基本相同）。
2. 除 `key`、`forms`、`contexts`、`createdAt`、`updatedAt` 以外的每个字段（`term`、`lemma`、`meaning`、`chrome`、`ios`、不认识的字段）：较新一边有就用它的，没有就用另一边的。
3. `forms`：并集，按码点排序，只留前 20 个。
4. `contexts`：按 `id` 取并集。同一 id：`savedAt` 大的那条为准，一样大则有 `meaning` 的为准，再一样取较新那一边的；其余字段（含 `meaning` 和不认识的字段）它没有就用另一条的。之后只留 `savedAt` 最大的 20 条（`savedAt` 一样按 id 的码点顺序，小的优先保留）；写出时按 `savedAt` 升序，再按 id。
5. `createdAt` 取较小，`updatedAt` 取较大。

**为什么一个文件也不会丢改动**：Drive v3 没有"文件没被别人改过才写"的条件写入，两端几乎同时写时，后写的会覆盖先写的。但每端本机都保留完整副本，合并满足交换律、幂等，被覆盖的改动会在那一端下次同步时重新合并上去。最多晚一些出现，不会丢。

## 7. 同步流程

1. 在 `WikiReader Cache/` 里找 `vocab.json`。
   - 没有：本机有词条或墓碑就新建一个 v2 文件。
   - 有：列表里的 `md5Checksum` 与上次成功同步时相同、本机也没改过，就到此为止，连下载都省掉。
2. 下载并检查 `formatVersion`：
   - `2`：继续。
   - `1`：只有 Chrome 把它转成 v2（key 按 §3 重新算）。**iOS 不读也不写 v1**，提示"等 Chrome 插件更新生词本格式"。
   - 其他：两端都不读不写，提示版本不认识。
3. `M = merge(L, R, now)`，写回本机（被别的设备删掉的词从本机消失，新词出现）。
4. `M` 与 `R` 比较（忽略顶层的 `updatedAt`、`updatedBy` 和顺序），不同才上传（覆盖同一个文件）。

时机：
- iOS：App 回到前台；收藏、删除、生成释义后约 5 秒（合并多次操作）；连接 Drive 后；打开生词本时。
- Chrome：打开生词本页；加词、解释、删除后约 4 秒；连接 Drive 后；浏览器开着时每 30 分钟一次。

## 8. 迁移

- **Chrome**：读到 v1（`app: "chrome"`、`entries[].word`）时转成 v2，之后只写 v2。旧版插件遇到 `formatVersion ≠ 1` 会拒绝写入，不会弄坏文件。
- **iOS**：原来每篇文章各有一份 `savedWords`（`Article.savedWordsData`）。第一次启动新版时全部转进全局生词本，只转一次：
  - 每个 `SavedWord` 生成一个词条：`key = normalize(term)`、`term`、`forms = [word]`、`lemma`、`meaning`、`createdAt = updatedAt = savedAt`；
  - 原句一条：`sentence`、`url` = 文章 `sourceURL`、`title` = 文章标题、`savedAt`、`meaning`；
  - 同一个 key 出现在几篇文章里时，用 `mergeEntry` 合成一条。
  - 文章里的 `savedWordsData` 保留不删，作为旧版本的回退。

## 9. 测试向量（`WikiReaderTests/Fixtures/shared/vocab/`）

| 文件 | 内容 |
|---|---|
| `normalize.json` | `[{input, key, sentence}]`：`key = normalize(input)`、`sentence = normalizeSentence(input)`、`id` = 原句 id |
| `term_key.json` | `[{word, term, key, lemma, group}]`：用完整 ECDICT 算出，不涉及 NLTagger |
| `match.json` | `{keys, cases: [{word, result}]}`：生词本里有 `keys` 这些词时，原文里 `word` 的判断，`result` 是 `saved`、`related` 或 `none` |
| `merge.json` | `[{name, now, local, remote, expected}]`：`expected` 不含顶层 `updatedAt`、`updatedBy`；比较时其余内容和顺序都要一致。除注明平局的用例外，交换 `local`、`remote` 结果也必须一样 |
