# 简单学 · SimpleXue

一个使用 SwiftUI 编写的本地 iPad 学习 App，将单词记忆、错题复习、语音默写、心算练习和英文听读整合到同一入口。

当前版本：**1.0（构建 4）**。仅支持 **iPadOS 27 及以上**。

## 功能

| 模块 | 主要功能 |
| --- | --- |
| 简单记 | 单词导入、双向卡片复习、FSRS 间隔复习、Apple Pencil 英文默写、学习统计与 JSON 备份 |
| 简单练 | JSON 错题导入、练习与订正、间隔复习、未完成会话恢复、题库备份 |
| 简单默 | 中英文词语朗读、重读、自动切词、倒计时与数据恢复 |
| 简单算 | 加减乘除及混合心算、练习计时、成绩与历史统计、数据恢复 |
| 简单听 | 粘贴 Markdown 文章、系统英文语音连续朗读、四档语速、播放顺序、循环与 Sleep Timer |

在首页选择功能，结束本轮后点击“切换功能”返回。简单练的未完成会话须先完成；简单听播放或暂停时须先停止。

## 构建与安装

需要一台安装 **Xcode 27 或更高版本**的 Mac，以及运行 iPadOS 27 或更高版本的 iPad。Apple Pencil 默写需要兼容的 Pencil 和真机。

1. 克隆仓库，然后打开 `SimpleXue.xcodeproj`。
2. 选择 **SimpleXue** 方案，在 **Signing & Capabilities** 中选择自己的开发团队。若模块提示缺少 Team，也为该 target 选择同一团队。
3. 首次安装到自己的设备时，将 App 和模块的 Bundle Identifier 设置为自己的唯一标识；后续更新保留同一标识，以保留已有数据。
4. 选择连接的 iPad，点击运行。开发者模式、信任与签名有效期按 Xcode 和设备提示处理。

```sh
git clone https://github.com/hutianyi/simple-learn.git
cd simple-learn
open SimpleXue.xcodeproj
```

仓库提供源代码，需自行构建和签名。工程已生成，首次打开无需 XcodeGen。FSRS 依赖固定到 `4fbaf20184d62f82a9f44f343337c61a2c5483e9`；首次构建时 Xcode 可能需要联网下载依赖。

修改工程生成配置后，可在仓库根目录使用已安装的 XcodeGen：

```sh
xcodegen generate
```

生成工程后需重新选择本机开发团队。个人签名信息不应提交到仓库。

## 数据与迁移

词库、题库、文章、学习进度和设置保存在设备本地。项目不提供账号系统、广告、分析服务、云同步或付费 AI API；系统语音下载及首次依赖下载可能需要网络。

各模块支持导出和恢复；恢复会替换对应模块数据。恢复前先结束当前学习，保存外部备份，恢复后核对记录数量、进度和设置。容器内的安全副本不能替代外部备份。

- **简单记**：使用旧 App 导出的完整 JSON 备份，在模块设置中恢复。
- **简单练**：使用旧 App 数据页导出的 JSON，在模块数据页恢复。
- **简单默／简单算**：从 Xcode 的 Devices and Simulators 下载旧 App 的 `.xcappdata` 容器，再用下列只读工具制作迁移 JSON。

以下命令在仓库根目录运行，假设容器已保存到桌面。工具读取容器并新建 JSON；同名输出已存在时拒绝覆盖。

```sh
python3 Scripts/export-legacy-data.py --module mo --container "$HOME/Desktop/简单默.xcappdata" --output "$HOME/Desktop/简单默迁移.json"
python3 Scripts/export-legacy-data.py --module suan --container "$HOME/Desktop/简单算.xcappdata" --output "$HOME/Desktop/简单算迁移.json"
```

容器和迁移文件包含个人学习数据，请存放在私人位置。迁移验收完成前保留旧 App 与备份。

## 验证

在仓库根目录运行现有核心测试。脚本在 `/private/tmp` 创建临时 Swift 包和缓存，不导入个人学习数据。

```sh
python3 Scripts/run-core-validation.py
python3 Scripts/run-listen-validation.py
```

核心测试覆盖导入、数据持久化、备份、复习规则、迁移与听读队列等逻辑。可用以下命令验证无签名模拟器编译：

```sh
xcodebuild -project SimpleXue.xcodeproj -scheme SimpleXue \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/SimpleXueOpenSourceBuild \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

运行完整 iPad 测试需要 iPadOS 27 模拟器或真机。核心测试和编译通过不能代替 Pencil 识别、系统声音、锁屏续播、Sleep Timer、横竖屏和真实备份恢复的设备验收。

## 项目结构

- `App/`：App 入口、首页、图标和配置。
- `Shared/`：模块切换、音频协调与数据迁移界面。
- `Modules/`：五个功能模块及各自测试。
- `Tests/`：共享核心测试和界面测试。
- `Scripts/`：本地验证与旧容器只读导出工具。
- `project.yml`、`SimpleXue.xcodeproj`：工程生成配置和已生成工程。
- `Attributions/`：来源说明、原许可证和接入时文件哈希。

个人开发进度、设备记录、备份和构建产物不包含在公开仓库中。

## 许可与署名

本项目按 [MIT License](LICENSE) 开源。原模块与第三方来源说明见 [NOTICE](NOTICE) 和 [Attributions](Attributions/README.md)。FSRS 使用官方 [swift-fsrs](https://github.com/open-spaced-repetition/swift-fsrs) 包，其 MIT 许可单独保留。

仓库不附带个人词库、文章材料、学习记录或备份。导入内容的权利由其原作者或使用者保留。
