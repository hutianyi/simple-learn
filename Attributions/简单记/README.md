# 简单记

`WordMemoryCards` 是本项目保留的内部工程、模块和数据容器名称；App 对用户显示为“简单记”。

> 本版仅面向 iPadOS 27。Apple Pencil 默写已接入；手写识别与完整学习流程仍需在真机验收。

An offline, iPad-first vocabulary flashcard app for family learning. Import a
simple Markdown or plain-text word list, then let the app schedule two
independent review directions: English to Chinese and Chinese to English.

The app starts with an empty word library. Vocabulary, review history, and
backups stay on the device unless the user explicitly exports a backup file.

## Features

- Import, edit, search, and remove user-owned vocabulary.
- Direction-specific FSRS-6 spaced repetition with a simple two-button review flow.
- Same-session retry, weak-item practice, progress reports, and streaks.
- On-device English and Chinese speech, adjustable speech rate, and haptics. Audio-session activation is asynchronous to avoid blocking the interface.
- JSON backup and restore with validation and a safety backup before restore.
- Apple Pencil 英文默写：首次抄写、30 秒正式首测、错词抄写与重默，使用独立的 FSRS 进度。首次和错词抄写每开始一遍自动朗读英文，沿用设置中的声音和语速。
- 默写手写不匹配时先显示识别结果、隐藏正确答案，允许一次字母键盘复核：键盘打开后独立计时60秒，无联想/自动纠错；正确算通过，错误或超时判错进入下一词，每题只保存一次最终成绩。抄写连续三次未通过仍可用键盘输入一次完成剩余抄写，纠错训练支持“稍后再练”。
- 一次性旧词摸底：首次运行新版时自动固定今天之前加入且尚未正式默写的旧词；摸底期间每天最多 50 个，完成后恢复常规默认 20 个，新词继续走原有入门流程。
- 词库的单词详情提供“不再参加默写”开关，立即保存，可随时关闭恢复；排除的词不再进入旧词摸底、首次抄写或普通默写，卡片复习保留，名单随完整备份保存。
- iPad-only SwiftUI interface, supporting portrait and landscape on iPadOS 27+.

## Build and run

1. Clone this repository on a Mac with Xcode.
2. Open `WordMemoryCards.xcodeproj` in Xcode.
3. In **Signing & Capabilities**, choose your own Apple Development Team.
4. If Xcode reports a bundle identifier conflict, change it to one you own.
5. Select an iPadOS 27 simulator or an iPad running iPadOS 27, then press Run. 默写手写识别须在 Apple Pencil 真机上验收。

`project.yml` is the XcodeGen project definition. If you change it, install
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate`
from the repository root to regenerate the committed Xcode project.

## Tests

With an iPadOS 27 iPad Simulator booted, run the following from the repository root:

```sh
xcodebuild test -parallel-testing-enabled NO \
  -project WordMemoryCards.xcodeproj \
  -scheme WordMemoryCards \
  -destination 'platform=iOS Simulator,name=iPad (A16)'
```

The project has unit tests for parsing, import, spaced repetition, queues,
persistence, backup, and progress reset, plus two UI smoke tests. Serial test
execution is used because this Xcode version can intermittently terminate two
UI-test runner launches when scheduled concurrently.

## Privacy

简单记 has no account system, analytics, advertising SDK, server API,
or bundled vocabulary corpus. The content you add and your learning history are
stored locally in the app's Core Data database. Exported backups are ordinary
files that you choose where to save and share.

## Attribution

This app was independently implemented for an iPad-first, two-direction spaced
repetition workflow. Its architecture and selected general-purpose interaction
patterns were informed by [TOEFL Vocab](https://github.com/a1mohamad/toefl-vocabs-ios-app)
by Amir Mohammad Askari, released under the MIT License.

The upstream project's copyright and MIT notice are preserved in
[LICENSE](LICENSE), with additional attribution in [NOTICE](NOTICE). The
detailed adaptation record is in [REUSE_PLAN.md](REUSE_PLAN.md). No upstream
TOEFL/504 word lists, screenshots, or publisher-owned material are included.

Review scheduling uses the official
[swift-fsrs](https://github.com/open-spaced-repetition/swift-fsrs) package under
its MIT License. The dependency is pinned to a reviewed FSRS-6-capable commit.

## License

简单记 is distributed under the MIT License. See [LICENSE](LICENSE)
and [NOTICE](NOTICE).
