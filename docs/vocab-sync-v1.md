# 生词本接口 v1：以网站为准的同步（English Reader ↔ iPhone WikiReader / Chrome 插件）

- 版本：v1，2026-11-07（同日按插件端的审阅意见补了 5 处：User-Agent、`serverTime`、预览上限 32 MB 和 gzip、授权页的跳转、什么时候走全量同步；另加 `device_id` 换钥匙；又按 iPhone 端的评审改了 4 处：前台每 30 秒拉取和网页自动刷新、撤销不删除同步加进来的词、预览跳过不合格的词条、`kept_newer` / `deleted_elsewhere` 的示例；App 内撤销改为先调接口、成功后再恢复本机）。2026-11-07 08:06 UTC 网站接口上线。站长确认方向：「你就按照你当前设计的流程，去出一个对应的规范吧…到时候我会让 iPhone App 和谷歌 Chrome 浏览器插件那边，按照你的 API 和规范来改」。
- 读者：iPhone App（WikiReader）和 Chrome 插件的开发者。网站一端按本文实现接口；两个客户端按本文改代码。
- 网站 SPEC 里的位置：§7.6。数据格式和合并规则仍然以 iOS 仓库的 `docs/shared-vocab-format.md`（v2）为准，本文不改格式，只规定**怎么通过网站交换**。

## 0. 一页看懂

1. **网站是生词本的中心**。每个账号的生词本以网站上的为准；iPhone 和插件各自留一份本机副本，通过网站接口同步，不再经过 Drive 上的 `vocab.json`（过渡期见 §9）。
2. **身份只看设备钥匙**。App / 插件在系统的安全登录窗口里登录网站，换到一把**设备钥匙**（每台设备一把），之后每个请求都带上它。请求里写的用户 id、邮箱一律不看。
3. **日常同步是增量的**：本机加词、删词后推给网站（§4.2）；定时向网站要「上次之后的变化」（§4.1）。冲突按 v2 规则自动合并，不需要用户操心。
4. **全量同步一定要用户确认两次**（§5）：先让网站对比两边、算出每种做法的结果；用户选方向（网站 → 本设备 / 本设备 → 网站 / 双向）和方式（只补缺 / 完全覆盖），看清会加几个、删几个；第二次确认时，要删网站上的词必须输入要删的数量。改动了网站的全量同步 30 天内可以撤销。

### 0.1 接口一览

| 方法 | 路径 | 用途 | 见 |
|---|---|---|---|
| GET | `/app/authorize` | 登录授权页（在系统安全窗口里打开，不是 JSON 接口） | §2.2 |
| POST | `/api/app/v1/auth/token` | 一次性授权码 + PKCE 暗号 → 设备钥匙 | §2.3 |
| POST | `/api/app/v1/auth/logout` | 退出这台设备（作废当前钥匙） | §2.5 |
| GET | `/api/app/v1/me` | 当前账号和这台设备的信息 | §2.5 |
| GET | `/api/app/v1/vocab/changes` | 增量拉取：某个游标之后的新增、修改、删除 | §4.1 |
| POST | `/api/app/v1/vocab/changes` | 批量推送：加词、改词、删词（离线攒下的一起发） | §4.2 |
| PUT | `/api/app/v1/vocab/words/{key}` | 加一个词或改一个词 | §4.3 |
| DELETE | `/api/app/v1/vocab/words/{key}` | 删一个词 | §4.3 |
| GET | `/api/app/v1/vocab/words/{key}` | 查一个词 | §4.3 |
| POST | `/api/app/v1/vocab/sync/preview` | 全量同步第 1 步：上传本机整本，网站算出差异和每种做法的结果 | §5.2 |
| POST | `/api/app/v1/vocab/sync/apply` | 全量同步第 2 步：按用户选的做法执行（必须带确认数字） | §5.4 |
| POST | `/api/app/v1/vocab/sync/undo` | 撤销一次改动了网站的全量同步（30 天内） | §5.5 |

## 1. 总则

沿用文章接口的约定（`docs/from-ios/site-api-for-ios.md` §1、§10），另加几条：

1. **地址**：`https://english.thrones.wang`，只走 HTTPS。`/api/app/*` 和 `/app/authorize` 不会被 Cloudflare 的质询拦截。
2. **JSON**：UTF-8；时间一律是 Unix 毫秒整数；没有值的字段省略，不写 `null`；客户端忽略不认识的字段（网站加字段不另行通知）；改字段含义、删字段、改类型算不兼容，要换 `/api/app/v2/`。
3. **请求头**：
   - `Authorization: Bearer erd_…`（设备钥匙，§2）。生词本接口全部要求带；没带或无效返回 401。
   - `User-Agent`：iPhone 用 `WikiReader/<版本> (iOS app)`，不要带邮箱。Chrome 里的 `fetch` 改不了 User-Agent（会被静默忽略），插件不用管。**网站不靠 User-Agent 区分客户端**，客户端类型以设备钥匙登记时的 `client` 为准。
   - 有请求体时 `Content-Type: application/json`。
4. **错误**：`{"error":{"code":"…","message":"…"}}`，状态码见 §7。`message` 是给开发者看的英文，界面上的提示由客户端按 `code` 自己写。
5. **请求体上限**：一般 5 MB，一次推送最多 500 条变化（§4.2；词条大的话按大小再拆小批）。全量同步的预览（§5.2）要一次传整本，上限 **32 MB**。预览可以用 gzip 压缩请求体（请求头 `Content-Encoding: gzip`，上限按解压后算），插件可用 `CompressionStream('gzip')`。
6. **缓存**：生词本接口都是 `Cache-Control: no-store`，不用 ETag。
7. **设备钥匙也能读文章**：文章接口（`/articles`、`/articles/{id}`、`/categories`）接受设备钥匙，效果等于「这个账号在网站上登录后阅读」（全文 + 网站对登录用户的每小时限速，SPEC §3.4）。所以登录后的 App 可以不再填站长签发的访问凭证 `er_…`；没登录的 App 仍可以用访问凭证。

## 2. 登录：拿设备钥匙（授权码 + PKCE）

原则：App 和插件**不保存密码、不内置任何代表用户的密钥**。用户在系统的安全登录窗口里登录**网站**（Google 或邮箱验证码，和网页上完全一样），网站发一张一次性授权码，客户端带着自己生成的暗号把它换成设备钥匙。Google 只在网站登录那一步出现，之后和 Google 无关。

### 2.1 准备

每次登录前，客户端生成：

- `code_verifier`：43–128 个字符，取自 `A-Z a-z 0-9 - . _ ~`（建议 32 个随机字节做 base64url，得到 43 个字符）。**只留在本机内存里，任何时候都不放进 URL。**
- `code_challenge` = base64url( SHA-256( `code_verifier` ) )，去掉末尾的 `=`。
- `state`：16 个以上随机字节的 base64url，回调时核对，防止别人伪造回调。

### 2.2 打开授权页

在系统安全窗口里打开：

```
https://english.thrones.wang/app/authorize
  ?client=ios                      ← ios 或 chrome
  &redirect_uri=wikireader%3A%2F%2Fauth%2Fcallback
  &code_challenge=<…>
  &code_challenge_method=S256      ← 只支持 S256
  &state=<…>
  &device_name=Tom%E2%80%99s%20iPhone   ← 可选，≤ 60 字，显示在账号页的设备列表里
```

| 客户端 | 系统窗口 | `redirect_uri` |
|---|---|---|
| iPhone | `ASWebAuthenticationSession`，`callbackURLScheme` = `wikireader`；`prefersEphemeralWebBrowserSession = false`（能沿用 Safari 里已登录的网站会话，少输一次） | `wikireader://auth/callback` |
| Chrome 插件 | `chrome.identity.launchWebAuthFlow({ url, interactive: true })`，manifest 加 `identity` 权限 | `chrome.identity.getRedirectURL('auth')`，即 `https://<插件 ID>.chromiumapp.org/auth` |

- 网站只接受登记过的 `redirect_uri`。**插件请把正式版和开发版（未打包）的插件 ID 告诉站长**，网站加进白名单（配置项 `APP_CHROME_EXTENSION_IDS`）。
- 点 Allow 是普通的表单提交，网站再用 303 跳到 `redirect_uri`。网站的 CSP 现在没有 `form-action` 限制；以后加的话会放行 `https://*.chromiumapp.org` 和 `wikireader:`，否则 Chrome 会在授权页卡住。
- 网站上的流程：
  1. 没登录 → 显示网站登录页（Google / 邮箱验证码），登录后回到授权页；
  2. 已登录 → 显示确认页：「WikiReader（iPhone）想读取和修改你的生词本。当前账号：x@…」，按钮「Allow」「Cancel」，以及「换个账号」；
  3. 点 Allow → 跳到 `redirect_uri?code=<授权码>&state=<原样返回>`；点 Cancel → `redirect_uri?error=access_denied&state=…`。
- 不在网站白名单里的邮箱登录不了（SPEC §3.3），授权页直接显示原因，不跳回客户端。
- 授权码：一次性，**60 秒内有效**，和这次的 `client`、`redirect_uri`、`code_challenge`、`device_name` 绑定。

### 2.3 换设备钥匙

客户端先核对 `state` 和发出去的一致，不一致就丢弃，提示登录失败。然后：

```
POST /api/app/v1/auth/token
{
  "grant_type": "authorization_code",
  "code": "<授权码>",
  "code_verifier": "<2.1 的原暗号>",
  "client": "ios",
  "redirect_uri": "wikireader://auth/callback",
  "device_id": "dev_7Hc…"
}
```

- `device_id`（可选）：这台设备上次登录得到的 `device.id`（比如收到 401 后重新登录）。带上的话，网站作废同一账号下这台设备的旧钥匙，账号页不会多出一台重复的设备。网站**不按设备名去重**（iPhone 的名字往往都叫「iPhone」）；没带 `device_id` 就算一台新设备，旧的那台 180 天不用自动失效，用户也可以在账号页退出它。

成功 200：

```json
{
  "device_token": "erd_3QmUq2…（共 47 个字符）",
  "device": { "id": "dev_7Hc…", "name": "Tom’s iPhone", "client": "ios", "createdAt": 1762500000000 },
  "user": { "email": "tom@example.com", "name": "Tom" }
}
```

- 失败一律 400 `invalid_grant`（授权码过期、用过、不存在，暗号对不上，`redirect_uri` / `client` 不一致）。不要重试同一个授权码，重新走 §2.2。
- `device_token` 只在这里出现一次，网站只存它的 SHA-256。

### 2.4 保存和使用

- iPhone：存钥匙串，`kSecClassGenericPassword`，可访问性 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（只在本机，不进 iCloud 钥匙串）。
- 插件：`chrome.storage.local`（不要用 `storage.sync`）。
- 每个请求带 `Authorization: Bearer <device_token>`。
- 收到 401 `invalid_token`（被退出、被站长作废、180 天没用过自动失效）：删掉本机保存的钥匙和游标，提示「Please sign in again」，**本机的生词本和待推送的变化保留**；重新登录后走 §5 的全量同步（会自动带出差异让用户确认）。
- **本机生词本绑定账号**：本机副本属于登录的那个网站账号（以 `user.email` 为准）。换账号登录时，旧账号的本机副本单独保存，不要合并进新账号（和现在 iPhone 按 Google 账号分开存的做法一样）。

### 2.5 退出和设备信息

- `POST /api/app/v1/auth/logout`（空请求体）→ 204，当前钥匙立即作废。客户端随后删掉钥匙和游标。
- `GET /api/app/v1/me` →

```json
{
  "user": { "email": "tom@example.com", "name": "Tom" },
  "device": { "id": "dev_7Hc…", "name": "Tom’s iPhone", "client": "ios", "createdAt": 1762500000000, "lastUsedAt": 1762586400000 },
  "vocab": { "count": 412, "cursor": "1873" }
}
```

- 网站账号页（`/account`）列出每台设备（名字、类型、登录时间、最近使用），每台旁边有「Sign out this device」。站长在后台用户页也能作废某个用户的全部设备。

## 3. 数据格式

### 3.1 词条

接口里的词条**就是 v2 格式的一个 entry**（`shared-vocab-format.md` §2），客户端本机副本里的样子原样发、原样收：

```json
{
  "key": "take off",
  "term": "take off",
  "lemma": "take off",
  "forms": ["took off"],
  "createdAt": 1762400000000,
  "updatedAt": 1762401234000,
  "meaning": "起飞；脱下",
  "contexts": [
    { "id": "3f2a9c0b1d4e5f60", "sentence": "The plane took off at noon.", "url": "https://english.thrones.wang/a/flight", "title": "Flight", "savedAt": 1762400000000 }
  ],
  "ios": { "…": "iOS 自己的字段，网站原样保留" },
  "chrome": { "…": "插件自己的字段，网站原样保留" },
  "web": { "…": "网站自己的字段，客户端原样保留" }
}
```

- `key` 按 v2 §3.1 的规则从 `term` 算出来，网站不重新计算，也不改写。
- 每一层不认识的字段都要原样保留，再发回网站时带上（和 Drive 同步时的要求一样）。
- 网站检查：`key`、`term` 非空且不超过 200 字；`createdAt`、`updatedAt` 是正整数；`forms` 是字符串数组；`contexts` 每条有 `id`（≤ 64 字）、`sentence`（≤ 2000 字）、`savedAt`。不合格的词条单独报 `invalid_entry`（§4.2），不影响同一批里的其他词条。
- **时间不能在未来**：`updatedAt`、`createdAt`、`savedAt`、`deletedAt` 比网站时间晚 10 分钟以上，整条拒绝，报 `clock_skew`，并在同一个对象里带 `serverTime`（网站当前时间，Unix 毫秒）。手机时间错了的话，「新的修改优先」会让它的改动永远压过别人，所以要挡住。预览（§5.2）里有这样的词条时不会让整个预览失败，而是跳过、列进 `rejected`（同样带 `serverTime`）。

### 3.2 删除记录

```json
{ "key": "take off", "deletedAt": 1762402000000 }
```

和 v2 的 `deleted` 墓碑一个意思：`deletedAt` 不早于词条的 `updatedAt` 就删掉它；之后又重新收藏（`updatedAt` 更新）就回来。网站保留墓碑一年，和 v2 一样。

### 3.3 合并规则

网站和客户端都只用 v2 §6 的规则合并（`mergeEntry`、墓碑比较），网站的实现就是 `core/shared/vocabV2.ts`。所以同一个词在两边被改过时，谁先推、谁后推，结果都一样。

## 4. 日常同步（增量）

网站给每个账号的每次变化（加词、改词、合并、删除）编一个递增的序号。客户端记住自己见过的最后一个序号，叫**游标**（`cursor`，字符串，客户端不要解析它，原样存、原样发）。新设备的游标是 `"0"`。

### 4.1 拉取：`GET /api/app/v1/vocab/changes?since=<cursor>&limit=500`

```json
{
  "entries": [ { "key": "take off", "…": "完整的 v2 词条" } ],
  "deleted": [ { "key": "ubiquitous", "deletedAt": 1762402000000 } ],
  "cursor": "1873",
  "more": false,
  "count": 412
}
```

- 按序号从旧到新给出 `since` 之后变过的词条（给完整词条，不是差量）和删除记录。`limit` 默认 500，最大 1000。
- `more: true` 时，用返回的 `cursor` 接着拉，直到 `more: false`。
- 客户端把收到的词条按 v2 规则合并进本机副本，处理删除记录，**全部写好以后**再保存新游标（中途失败就用旧游标重拉，合并是幂等的，重复收到没关系）。
- `count`：网站上这个账号现在一共多少个词，客户端可以拿来和本机比对、显示。
- **410 `cursor_expired`**：游标太旧（早于一年前清理掉的墓碑），增量已经补不全了。客户端要走 §5 的全量同步。

### 4.2 推送：`POST /api/app/v1/vocab/changes`

本机的新增、修改、删除先进待推送队列，攒一会儿（约 5 秒，多次操作合成一次）一起推。离线时留在队列里，联网后再推。

```json
{
  "requestId": "6f1c2e0a-…",
  "changes": [
    { "type": "upsert", "entry": { "key": "take off", "…": "完整的 v2 词条（本机合并后的版本）" } },
    { "type": "delete", "key": "ubiquitous", "deletedAt": 1762402000000 }
  ]
}
```

- `requestId`：客户端为这一批生成的 UUID。网络断了不知道成没成功时，**用同一个 `requestId` 重发**，网站 24 小时内认得它，直接返回上次的结果，不会重复处理。
- 一批最多 500 条；更多就分批。

返回 200（只要请求本身合法就是 200，每条的结果分开给）：

```json
{
  "results": [
    { "key": "take off", "status": "merged", "entry": { "…": "网站合并后的完整词条" } },
    { "key": "ubiquitous", "status": "deleted" },
    { "key": "serendipity", "status": "kept_newer", "entry": { "…": "网站上更新的完整词条，放回本机" } },
    { "key": "ephemeral", "status": "deleted_elsewhere", "deletedAt": 1762402100000 },
    { "key": "quixotic", "status": "clock_skew", "message": "A time in this entry is in the future: check the device clock", "serverTime": 1762402500000 }
  ],
  "count": 413
}
```

| `status` | 含义 | 客户端怎么做 |
|---|---|---|
| `created` | 网站上没有，新建了 | 用返回的 `entry` 覆盖本机这条（内容一样，保险起见） |
| `merged` | 网站上有，按 v2 规则合并了 | 用返回的 `entry` 覆盖本机这条 |
| `unchanged` | 网站上已经是这个内容 | 无 |
| `deleted` | 删掉了（或网站上本来就没有，记下了删除记录） | 无 |
| `kept_newer` | 要删的词在网站上有**更晚**的修改（别的设备后来又收藏或改过），没删 | 用返回的 `entry` 把这个词放回本机，去掉本机的删除记录 |
| `deleted_elsewhere` | 要加的词在网站上有**更晚**的删除记录（别的设备后来删了它） | 从本机删掉这个词，记下返回的 `deletedAt` |
| `invalid_entry` / `clock_skew` | 这条不合格（§3.1），没处理；`message` 说明原因，`clock_skew` 时还有 `serverTime` | 从队列里拿掉，记日志；`clock_skew` 时提示用户检查设备时间 |

- 推送**不移动游标**。推完以后照常做一次 §4.1 的拉取（会收到自己刚推的变化，合并是幂等的，没关系）。这样不会漏掉其他设备在这期间的改动。

### 4.3 单个词的便捷接口

给「点一下收藏 / 删除」这种场景用，和 §4.2 只有一条变化时完全等价，返回同样的结果对象（不包在 `results` 里）。

- 加词或改词：`PUT /api/app/v1/vocab/words/{key}`，请求体是完整的 v2 词条，`entry.key` 必须和路径里的一样（不一样返回 400）。
- 删词：`DELETE /api/app/v1/vocab/words/{key}?deletedAt=<毫秒>`（不带 `deletedAt` 就用网站当前时间）。
- 查词：`GET /api/app/v1/vocab/words/{key}` → `{"entry": {…}}`；没有返回 404，如果有删除记录，返回体带 `{"deletedAt": …}`。
- 路径里的 `{key}` 按 UTF-8 做 percent-encoding（`encodeURIComponent`），比如 `take%20off`。

### 4.4 什么时候同步

| 时机 | iPhone | 插件 |
|---|---|---|
| 本机加词、删词、改释义后约 5 秒 | 推送，然后拉取 | 推送，然后拉取 |
| App 回到前台 / 浏览器启动、插件后台被唤醒 | 拉取 | 拉取 |
| 定时 | App 在前台时每 30 秒拉取一次（不要更频繁） | 每 15 分钟拉取一次（`chrome.alarms`），打开弹窗 / 侧边栏时也拉取 |
| 打开生词本页面 | 拉取 | 拉取 |
| 第一次登录、收到 `cursor_expired`、用户手动点「全量同步」 | §5 | §5 |

- **网页这边**：生词本页和阅读页在窗口重新获得焦点时立刻刷新，页面开着时每 60 秒刷新一次，所以手机上刚收藏的词，网页上不用手动刷新也会出现。
- 失败时指数退避重试（2、4、8… 秒，最长 5 分钟）。429 按 `Retry-After` 等待。
- 界面上显示同步状态：已同步 / 正在同步 / 离线（有 N 个改动待推送）/ 需要重新登录 / 失败（附原因）。

## 5. 全量同步（必须二次确认）

### 5.1 什么时候用

- 一台设备**登录以后**（第一次登录，或收到 401 后重新登录），本机已经有词（比如以前通过 Drive 同步攒下的）；本机是空的就不用，直接 `since=0` 拉取。
- 收到 410 `cursor_expired`。
- 用户在设置里手动点「全量同步 / Full sync」。

全量同步**不会自动执行**，一定先预览（§5.2），用户选好做法（§5.3）、再确认一次（§5.4）才执行。

### 5.2 第 1 步：预览差异 `POST /api/app/v1/vocab/sync/preview`

客户端把本机整本发给网站，格式就是本机的 v2 文件（`entries` + `deleted`）：

```json
{ "formatVersion": 2, "entries": [ … ], "deleted": { "ubiquitous": 1762402000000 } }
```

网站逐个词对比两边，把每个词归到下面一类（同一个 `key` 才算同一个词）：

| 类别（字段名） | 含义 |
|---|---|
| `same` | 两边都有，内容完全一样 |
| `differ` | 两边都有，内容不一样（再分：`deviceNewer` 本机较新，`serverNewer` 网站较新，按 v2 的 `updatedAt` 比） |
| `deviceOnly` | 只在本机有，网站上从没有过，或者网站上的删除比本机这条的修改还早 |
| `deviceOnlyDeletedOnServer` | 只在本机有，但网站上有**更晚**的删除记录（在别的设备或网页上删过） |
| `serverOnly` | 只在网站上有，本机从没有过，或者本机的删除比网站这条的修改还早 |
| `serverOnlyDeletedOnDevice` | 只在网站上有，但本机有**更晚**的删除记录（你在这台设备上删过） |

返回 200：

```json
{
  "previewId": "pv_Xk3…",
  "expiresAt": 1762500600000,
  "counts": {
    "device": 50, "server": 40,
    "same": 30, "differ": 5, "deviceNewer": 3, "serverNewer": 2,
    "deviceOnly": 12, "deviceOnlyDeletedOnServer": 3,
    "serverOnly": 3, "serverOnlyDeletedOnDevice": 2
  },
  "words": {
    "differ": [ { "key": "take off", "term": "take off", "newer": "device" } ],
    "deviceOnly": [ { "key": "…", "term": "…" } ],
    "deviceOnlyDeletedOnServer": [ { "key": "…", "term": "…", "deletedAt": 1762402000000 } ],
    "serverOnly": [ … ],
    "serverOnlyDeletedOnDevice": [ … ]
  },
  "options": {
    "merge":                     { "device": { "after": 50, "add": 3,  "remove": 3,  "update": 5 }, "server": { "after": 50, "add": 12, "remove": 2, "update": 5 } },
    "serverToDevice.add":        { "device": { "after": 53, "add": 3,  "remove": 0,  "update": 5 }, "server": { "after": 40, "add": 0,  "remove": 0, "update": 0 }, "skipped": { "serverOnlyDeletedOnDevice": 2 } },
    "serverToDevice.overwrite":  { "device": { "after": 40, "add": 5,  "remove": 15, "update": 5 }, "server": { "after": 40, "add": 0,  "remove": 0, "update": 0 } },
    "deviceToServer.add":        { "device": { "after": 50, "add": 0,  "remove": 0,  "update": 0 }, "server": { "after": 52, "add": 12, "remove": 0, "update": 5 }, "skipped": { "deviceOnlyDeletedOnServer": 3 } },
    "deviceToServer.overwrite":  { "device": { "after": 50, "add": 0,  "remove": 0,  "update": 0 }, "server": { "after": 50, "add": 15, "remove": 5, "update": 5 } }
  },
  "rejected": [ { "key": "quixotic", "status": "clock_skew", "message": "A time in this entry is in the future: check the device clock", "serverTime": 1762500000000 } ]
}
```

- `words` 每类最多列 200 个（按 `key` 排序）；超出时客户端显示「…还有 N 个」。
- **不合格的词条不会让整个预览失败**：不符合 §3.1 的词条或删除记录（格式不对、同一个 key 出现两次、时间在未来）跳过，列在 `rejected` 里（`[{"key", "status": "invalid_entry" | "clock_skew", "message", "serverTime"?}]`）。这些 key 在两边都不参与对比，五种做法都不会碰网站上的同名词；执行后返回的 `book` 里也没有它们，客户端用 `book` 替换本机副本时要**把这些 key 的本机数据原样留下**，修好以后再同步。
- 所有数字都由网站算，两个客户端只负责显示，保证 iPhone 和插件看到的一模一样。
- 预览 10 分钟内有效；网站保存这次上传的本机整本，第 2 步不用再传。

### 5.3 五种做法（用户要回答的两个问题）

**问题 1：方向**——网站 → 本设备 / 本设备 → 网站 / 双向。
**问题 2：方式**（单向时才问）——只补缺 / 完全覆盖。

| 做法（`option`） | 一句话 | 本设备 | 网站 |
|---|---|---|---|
| `merge` 双向合并（**默认，推荐**） | 两边合在一起，都变成同一本 | 补上网站多出的词；删掉在网站上后来被删的词；两边都有的按 v2 合并 | 补上本机多出的词；删掉你在本机后来删的词；两边都有的按 v2 合并 |
| `serverToDevice.add` 网站 → 本设备，只补缺 | 把网站上有、本机没有的词加到本机，不删任何词 | 加上 `serverOnly`；`differ` 按 v2 合并；**不加**你在本机删过的（`serverOnlyDeletedOnDevice`）；本机多出的词留着 | 不变 |
| `serverToDevice.overwrite` 网站 → 本设备，完全覆盖 | 本机变得和网站一模一样 | 加上网站上所有本机没有的（包括你在本机删过的）；**删掉本机多出的全部词**；`differ` 用网站的版本 | 不变 |
| `deviceToServer.add` 本设备 → 网站，只补缺 | 把本机有、网站没有的词加到网站，不删任何词 | 不变 | 加上 `deviceOnly`；`differ` 按 v2 合并；**不加**网站上后来删过的（`deviceOnlyDeletedOnServer`）；网站多出的词留着 |
| `deviceToServer.overwrite` 本设备 → 网站，完全覆盖 | 网站变得和本机一模一样 | 不变 | 加上本机所有网站没有的（包括网站上删过的）；**删掉网站多出的全部词**（其他设备下次同步也会删掉它们）；`differ` 用本机的版本 |

**例子：本机 50 个，网站 40 个**（就是 §5.2 返回的那组数字）。两边都有、一样的 30 个；都有但内容不同的 5 个；只在本机的 15 个，其中 3 个在网站上后来被删过；只在网站的 5 个，其中 2 个你在本机删过。

| 做法 | 完成后本机 | 完成后网站 | 说明 |
|---|---|---|---|
| 双向合并 | 50（+3 −3 改 5） | 50（+12 −2 改 5） | 55 个词里，网站上后删的 3 个和本机后删的 2 个按删除处理，两边都剩 50 个，一模一样 |
| 网站 → 本机，只补缺 | 53（+3 改 5） | 40（不变） | 你在本机删过的 2 个不加回来；本机多出的 15 个留着 |
| 网站 → 本机，完全覆盖 | 40（+5 −15 改 5） | 40（不变） | 本机多出的 15 个全删；你在本机删过的 2 个会回来 |
| 本机 → 网站，只补缺 | 50（不变） | 52（+12 改 5） | 网站上后删的 3 个不加回去；网站多出的 5 个留着 |
| 本机 → 网站，完全覆盖 | 50（不变） | 50（+15 −5 改 5） | 网站多出的 5 个删掉，**其他设备下次同步也会删**；网站上删过的 3 个会回来 |

单向做法做完，两边会继续不一样（这是用户选的）。之后的日常同步只交换新的变化，不会把这些差异自动补齐；想补齐就再做一次双向合并。

**覆盖要「盖得住」**：`deviceToServer.overwrite` 时，网站把这次写进去的词（新增的、换成本机版本的）的 `updatedAt` 记为执行时间，删掉的词的删除时间也记为执行时间。否则别的设备手里时间更新的旧版本，下次同步时会按「新的修改优先」把它改回去。这些词随后会通过日常拉取回到本设备（内容不变，只是时间更新），不用特别处理。合并和只补缺不改时间，完全按 v2 规则。

### 5.4 第 2 步：执行 `POST /api/app/v1/vocab/sync/apply`

```json
{
  "previewId": "pv_Xk3…",
  "option": "deviceToServer.overwrite",
  "confirm": { "deviceRemove": 0, "serverRemove": 5 }
}
```

- `confirm` 里的两个数必须**和预览里这个做法的 `device.remove`、`server.remove` 完全一样**，否则 422 `confirmation_mismatch`，什么都不做。这是网站这边的二次确认：客户端必须把要删多少个摆到用户面前、用户确认过才拿得到这两个数。
- 网站执行前再检查一次：这个账号的生词本在预览之后有没有变（别的设备推送过）。变了就 409 `changed_since_preview`，什么都不做；客户端提示「生词本刚刚有变化，请重新对比」，回到 §5.2。
- 预览过期 410 `preview_expired`，回到 §5.2。
- 整个执行在一个事务里，要么全做，要么全不做。

返回 200：

```json
{
  "option": "merge",
  "result": { "device": { "after": 50 }, "server": { "after": 50 } },
  "book": { "formatVersion": 2, "entries": [ … ], "deleted": { … } },
  "cursor": "1902",
  "undoId": "undo_9Qa…",
  "undoUntil": 1765100000000
}
```

- `book`：本设备应该变成的整本（`merge`、`serverToDevice.*` 才有）。客户端**用它整个替换本机副本**（包括 `deleted`），保存 `cursor`。
- `deviceToServer.*`：没有 `book`，本机不变，保存 `cursor`。
- 不管哪种做法，执行成功后都**清空待推送队列**：预览时上传的是包括未推送改动在内的整本，这些改动已经按用户选的做法处理过了，不能再推一次。所以预览前不要先推送，也不要在预览和执行之间修改本机的生词本（界面上锁住收藏 / 删除，或者有改动就重新预览）。
- `undoId`：这次改动了网站（`merge`、`deviceToServer.*` 且网站确实有变化）时才有，30 天内可以撤销（§5.5）。
- 只改本机的做法（`serverToDevice.*`）由客户端自己负责撤销：执行前把本机副本备份一份，至少保留到下次全量同步。

### 5.5 撤销：`POST /api/app/v1/vocab/sync/undo`

```json
{ "undoId": "undo_9Qa…" }
```

- 把那次全量同步对网站做的改动退回去：**删掉的词放回来，改过的词改回原样；这次同步加到网站上的词保留不动**——它们是从某台设备带上来的，在网站上删掉，那台设备下次同步时也会把它们删掉，就真的丢了。撤销**从不删除任何词**。
- 之后又被改过的词不动，在返回里列出来。
- 退回也是普通的变化（新的序号、新的时间），其他设备下次拉取时自然跟上。
- 返回 `{"restored": 5, "reverted": 5, "kept": 15, "skipped": [ { "key": "…", "reason": "changed_later" } ], "cursor": "1950"}`。`cursor` 已经包含撤销写入的所有变化。
- 在 App 里撤销：先调这个接口，成功后再把本机恢复成全量同步前的备份，然后保存返回的 `cursor`；接口失败时本机什么都不动，可以重试（2026-11-07 按 iPhone 端的实现改，这样更安全）。这个 `cursor` 已经包含撤销写入的所有变化，所以本机不会再把它们拉下来；两边各自回到全量同步之前的样子（之前两边本来不一样的地方，也照旧不一样，想对齐就再做一次全量同步）。
- 网站账号页也会列出最近 30 天的全量同步，带「Undo」按钮。

### 5.6 客户端界面要求（三个画面）

**画面 1：差异。** 标题「Full sync」，先说两边各有多少，再列 §5.2 的各类，每一类可以展开看词：

```
This device: 50 words · English Reader: 40 words
  Same on both ............................ 30
  On both, but different ................... 5   (newer here 3, newer on the site 2)
  Only on this device ..................... 15   (3 of them were deleted on the site later)
  Only on the site ......................... 5   (2 of them you deleted on this device)
```

**画面 2：选做法。** 先选方向（默认「Both ways」双向合并），选了单向再选方式（「Add missing only」只补缺 / 「Replace completely」完全覆盖）。每个选项下面直接写出结果，比如：

```
◉ Both ways (recommended)
    After: this device 50 · site 50
    This device: +3  −3  ✎5   ·  Site: +12  −2  ✎5
○ Site → this device
○ This device → site
```

**画面 3：二次确认。** 用一句话复述要做什么，把会删的词单独列出来：

- 两边都不删词（`device.remove` 和 `server.remove` 都是 0）：普通的「Sync」按钮。
- 要删本机的词：红字「15 words will be removed from this device」，列出这些词，按钮「Remove 15 and sync」。
- **要删网站的词**：红字「5 words will be deleted from English Reader, and from your other devices when they sync. You can undo this for 30 days on the website.」，列出这些词；用户必须在输入框里**输入要删的数字（5）**，按钮才变成可点。

执行完显示结果；改动了网站时显示「Undo」（调 §5.5）。

## 6. 设备管理和安全

- 设备钥匙：`erd_` + 43 个字符（32 个随机字节的 base64url）。网站只存 SHA-256，数据库泄漏也拿不到能用的钥匙。
- 一台设备一把钥匙；重新登录时带上 `device_id`（§2.3），网站换新钥匙、作废旧的。
- 180 天没用过的钥匙自动失效。
- 用户在网站账号页可以退出任意一台设备；站长在后台可以作废某个用户的全部设备。
- 身份只从钥匙查：生词本接口只读写钥匙所属账号的数据，请求体里的任何「用户」字段都不看。
- 网站每 6 小时备份一次数据库到站长的 Drive（已有）。

## 7. 错误码

| 状态码 | `error.code` | 什么时候 | 客户端怎么做 |
|---|---|---|---|
| 400 | `bad_request` | 参数或 JSON 不对 | 修代码；不要重试 |
| 400 | `invalid_grant` | 授权码不对、过期、用过，暗号不符 | 重新走 §2.2 |
| 401 | `invalid_token` | 没带钥匙、钥匙不存在、已退出或已作废 | 删钥匙和游标，提示重新登录（§2.4） |
| 403 | `not_allowed` | 账号被停用或不在白名单 | 提示联系站长 |
| 404 | `not_found` | 查的词不存在（§4.3） | — |
| 409 | `changed_since_preview` | 预览之后生词本又变了 | 重新预览 |
| 410 | `cursor_expired` | 游标太旧 | 走 §5 |
| 410 | `preview_expired` | 预览超过 10 分钟 | 重新预览 |
| 413 | `too_large` | 请求体超过上限（一般 5 MB，预览 32 MB）或一批超过 500 条 | 推送分批；预览超限时用 gzip 压缩，还不够就提示用户联系站长 |
| 422 | `confirmation_mismatch` | `confirm` 的数字和预览对不上 | 回到画面 3 重新确认 |
| 429 | `rate_limited` | 超过频率限制 | 按 `Retry-After`（秒）等待 |
| 503 | `maintenance` | 网站维护（部署时可能有几秒） | 稍后重试 |

单条词条的错误（`invalid_entry`、`clock_skew`）不用状态码表示：推送时放在 §4.2 的 `results` 里，预览时放在 §5.2 的 `rejected` 里。

## 8. 频率限制

| 范围 | 上限 |
|---|---|
| 每台设备所有生词本接口 | 每分钟 120 次 |
| 预览（§5.2） | 每台设备每小时 20 次 |
| 换钥匙（§2.3） | 每个 IP 每分钟 10 次 |

正常使用远到不了这些上限；超过时返回 429 和 `Retry-After`。

## 9. 过渡期：Drive 上的 `vocab.json`

1. **网站先上线这些接口**，同时继续按现在的方式读写 Drive 上的 `vocab.json`（给开了 Drive 同步的账号）。旧版 App 和插件照常工作。
2. **新版 App / 插件**登录网站以后，生词本只走网站接口，不再读写 Drive 上的 `vocab.json`。升级后第一次登录时，本机副本里已经有以前通过 Drive 同步来的词，走 §5 的全量同步（默认双向合并），用户确认后两边对齐。
3. 混用期间（一台设备是旧版、一台是新版），网站在中间同时连着 Drive 和接口，最终也会一致，只是旧版设备的改动要等网站和 Drive 同步一次才到达新版设备。
4. 所有设备都升级以后，站长决定什么时候停掉网站的 Drive 生词本同步。

## 10. 客户端自测清单

1. 登录：成功；在授权页点 Cancel；`state` 不一致时丢弃；授权码 60 秒后过期；同一个授权码用第二次失败；暗号不对失败。
2. 401：在网站账号页「Sign out this device」后，客户端下一次请求提示重新登录，本机的词还在。
3. 离线加 3 个词、删 1 个词，联网后一次推完；用同一个 `requestId` 重发，结果不变。
4. 设备 A 加词 → 设备 B 拉取后出现；B 删掉 → A 拉取后消失；A 再收藏同一个词（`updatedAt` 更新）→ 两边都回来。
5. `kept_newer`、`deleted_elsewhere` 两种结果都处理对（可以用两台设备先后操作造出来）。
6. 手机时间调快 1 小时再收藏，收到 `clock_skew`，界面有提示。
7. 全量同步：用 §5.3 的「50 / 40」造数据，五种做法各做一遍，核对数字和结果；`confirm` 数字故意填错得到 422；预览后在另一台设备改一个词，再执行得到 409；`deviceToServer.overwrite` 之后在网站上撤销，被删的词都回来、这次加上去的词还在。
8. 收到 410 `cursor_expired` 时进入全量同步（网站可以帮忙造这个情况）。
9. 浅色 / 深色、手机宽度下三个确认画面都看得清。

**建议用测试账号**：全量同步的覆盖会删词，测试时请站长在网站白名单里加一个测试邮箱，不要拿自己正在用的生词本试。

## 11. 网站这边要做的事（供参考，客户端不用管）

- 新表：设备（钥匙哈希、名字、类型、最近使用、作废时间）、一次性授权码、全量同步预览（10 分钟）、撤销记录（30 天）；词条和删除记录加全站递增的序号（客户端把 `cursor` 当不透明的字符串用即可）。
- 现有的网页收藏 / 删除、Drive 同步合并都要编序号，这样客户端拉得到。
- 账号页的设备列表、全量同步记录和撤销；后台用户页作废设备。
- 文章接口接受设备钥匙（§1 第 7 条）。
- 测试：v2 合并向量照常全部通过；接口的每种结果、每个错误码；五种全量同步做法用「50 / 40」数据核对。
