# 简单练

简单练是一款只在 iPad 本机运行的错题复习 App。题库由家长在 ChatGPT 中生成，再以 JSON 或 `simplelian-json` 代码块导入；孩子在纸上做题，回到 App 手动判定结果。

## 第一版包含

- JSON 解析、结构检查、Markdown 安全检查、导入预览、重复导入拦截。
- 今天队列：待首次练习和到期题型各取一道扩展题。
- 手动核对答案、题目问题停用、按题型订正、三次订正失败转为需要讲解。
- 跨日 1/3、2/3、3/3 掌握规则，以及 7 天、14 天、订正后 3 天的间隔。
- 未完成会话恢复、题库管理、完整 JSON 备份和恢复。

不包含 AI API、OCR、自动判题、云同步或 Apple Pencil 功能。

## App 图标

图标以练习卡、橙色对勾和三个复习进度点表现“练习—复习—掌握”。Xcode 使用 `SimpleLian/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`；较高分辨率的设计母版保存在 `Design/AppIcon-master.png`。

## 在 Xcode 打开

打开 `SimpleLian.xcodeproj`，选择 `SimpleLian` Scheme。工程目标是 iPadOS 27，只支持 iPad。

首次装到 iPad 时，在 Xcode 的 **Signing & Capabilities** 中为 `SimpleLian` Target 选择你的开发团队，然后连接 iPad、选择该设备并按运行按钮。工程默认 Bundle ID 是 `com.hutianyi.SimpleLian`；若它与现有 App 冲突，可在同一页面改成属于你的唯一标识。

## 本地验证

核心规则测试：

```sh
cd Core
swift test --scratch-path /private/tmp/simplelian-core-build
```

App 编译：

```sh
xcodebuild -project SimpleLian.xcodeproj \
  -scheme SimpleLian \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/SimpleLianDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

构建产物放在 `/private/tmp`，避免同步文件夹的扩展属性影响签名。
