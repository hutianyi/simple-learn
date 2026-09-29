# 来源与许可

简单学整合了同一作者维护的四个独立 App，并新增简单听模块。整个整合项目按根目录 MIT License 发布。

| 模块 | 原项目 | 保留的资料 |
| --- | --- | --- |
| 简单记 | https://github.com/hutianyi/word-memory-cards | 原 README、MIT LICENSE、第三方 NOTICE |
| 简单练 | https://github.com/hutianyi/simple-lian | 原 README |
| 简单默 | https://github.com/hutianyi/ios-dictation-app | 原 README |
| 简单算 | https://github.com/hutianyi/simple-suan | 原 README、MIT LICENSE |

各模块子目录的 README 是整合时保留的历史快照，工程路径、系统要求和许可描述可能与整合版不同。整合版的构建方法和许可以根目录 README、LICENSE、NOTICE 为准；简单练与简单默在本整合版中的代码也按根目录 MIT 许可发布。

`source-manifest.json` 记录接入时原文件相对于各原项目的来源及 SHA-256。它是来源记录，适配后的文件不一定与原始哈希相同；构建不依赖旁边的原工程。

简单记参考了 Amir Mohammad Askari 的 TOEFL Vocab 项目的架构与通用交互思路，原 MIT 署名完整保留。未包含上游 TOEFL / 504 词表、截图或出版商材料。

FSRS 来自官方 swift-fsrs 包，固定版本的原 MIT 文本保留在 `swift-fsrs/LICENSE`。
