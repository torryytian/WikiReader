# CLAUDE.md

## 项目

WikiReader：iPhone 上的英语阅读 App，抓取 Wikipedia 正文、朗读、点词查词典。
完整需求和分阶段验收标准见 @SPEC.md
各阶段进度、开发中做出的决定和待办见 @PROGRESS.md（每完成一个阶段或做出重要决定后更新它）

## 关于我

- 我是基础设施方向的工程师（分布式系统、Linux），熟悉 git 和命令行，但没写过 Swift，也没做过 iOS 开发。
- 遇到 iOS 特有的概念（签名、Capabilities、Info.plist、App 生命周期、MainActor 等）用一两句话解释，能类比到后端的概念更好。
- 和我交流用中文；代码、注释、commit message 用英文。

## 技术约束

- Swift + SwiftUI，部署目标 iOS 17.0，只做 iPhone 竖屏。
- 状态管理用 Observation（`@Observable`），持久化用 SwiftData，网络用 URLSession + async/await。
- 用 `NavigationStack`，不用已废弃的 `NavigationView`；新代码不用 `ObservableObject`。
- 只用系统框架（SwiftUI、UIKit、AVFoundation、NaturalLanguage、SwiftData），不引入第三方依赖；确实需要时先问我。
- UIKit 组件通过 `UIViewRepresentable` / `UIViewControllerRepresentable` 接入 SwiftUI。

## 目录结构

```
WikiReader/
  App/          入口、全局配置
  Models/       SwiftData 模型
  Services/     WikipediaClient、ArticleCleaner、SpeechEngine、DictionaryLookup
  Views/        Library、Reader、Settings
WikiReaderTests/
  Fixtures/     测试用的 API 返回样本
```

- 工程用 Xcode 16 及以上创建，源码目录是同步文件夹：新的 .swift 文件放进 `WikiReader/` 就会自动参与编译。
- 尽量不要手工编辑 `project.pbxproj`。需要改工程设置（Capabilities、Info.plist 键、签名等）时，优先告诉我在 Xcode 里怎么改；部署目标这类简单的单值修改可以直接改，改完重新编译确认。

## 构建与验证

- 每次改完代码：编译通过 → 在 iOS 模拟器里运行 → 亲自点一遍改动涉及的界面，确认效果。
- 命令行编译（模拟器名称用 `xcrun simctl list devices available` 查）：
  `xcodebuild -scheme WikiReader -destination 'platform=iOS Simulator,name=iPhone 15 Pro Max' build`
  跑单元测试把 `build` 换成 `test`，并加上 `-parallel-testing-enabled NO -collect-test-diagnostics never`（否则测试失败时 xcodebuild 会卡约 10 分钟收集诊断，并行测试还会克隆、关掉 iPhone 15 Pro Max 模拟器）。
- URL 解析和正文清洗必须有单元测试。测试用本地 fixture：先用 curl（带上下面的 User-Agent）抓一份真实的 API 返回，存进 `WikiReaderTests/Fixtures/`，测试运行时不访问网络。建议的样本：Albert Einstein（长文）、Paris（首句有音标）、Pythagorean theorem（有公式）。
- 你验证不了的部分，明确告诉我需要在真机上验收：朗读音质、高亮和声音是否同步、真机上的系统词典。

## 工作方式

- 按 SPEC.md 的阶段顺序推进，一次只做一个阶段。开始一个阶段前先给我一个简短计划，我确认后再写代码。
- 每完成一个能编译运行的小步，就 `git commit` 一次。
- 同一个错误连续修了 3 次还没解决，就停下来，告诉我你的判断、试过什么、还有哪些方案，由我决定。
- 不要为了让编译通过而删除功能、注释掉代码或跳过测试。
- 遇到 Swift 并发相关的编译错误（Sendable、actor 隔离），按正确的方式修，不要用 `@unchecked Sendable`、`nonisolated(unsafe)` 之类的写法硬绕过去；拿不准时先给我解释原因。
- 需要我手动操作的（Xcode 里的签名和 Capabilities、真机运行、iPhone 系统设置），写成清楚的步骤。

## 网络与安全

- 访问 Wikipedia 的每个请求都带 User-Agent：`WikiReader/0.1 (personal app; contact: torryytian@gmail.com)`
- 只在我添加文章时请求 Wikipedia，不预取、不批量抓。
- 选用 OpenAI 朗读时，只为当前段和下一段请求 `api.openai.com` 生成音频；生成结果缓存在本地，不重复请求，不批量生成全文。
- AI 讲解（词典界面的 AI 按钮）：只在我点按钮时请求 `api.openai.com/v1/chat/completions`，一次只发被查的单词和它所在的句子，不发全文，不预取，不自动触发；用的是设置页保存的同一个 OpenAI Key。
- 任何 API Key 都不写进代码、不提交到 git。以后接云端服务时，Key 在 App 的设置页输入，存 Keychain。
