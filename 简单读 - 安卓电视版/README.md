# 简单读 · 安卓电视版

电视版 0.1.2，支持 Android 7.0（API 24）及以上。导入现有 `.simpledu` v1 阅读包后，可离线选文章、图文翻页、做选择题及查看结果。电视独立保存进度。

主界面只显示未读文章，包括仍在阅读或答题的文章。已读文章可在右上角的「已读文章」中打开。正文读到末页，并提交全部题目后，退出文章即归入已读。重读或重做可以从已读文章打开。也可以通过 ADB 单独设置已读标记，该操作不添加答题记录。

电视版是独立 Android 工程，使用与 iPad 简单读相同的阅读包格式，独立构建、编号和保存进度。版本变化见 [更新记录](CHANGELOG.md)。

## 在 Mac 上构建

准备 JDK 17、Android SDK Platform 35 和 Build Tools 34.0.0，并配置 `JAVA_HOME` 与 `ANDROID_HOME`。在本目录执行以下命令生成调试 APK 和 Lint 报告。

```sh
mkdir -p "$PWD/.local/android"
ANDROID_USER_HOME="$PWD/.local/android" ./gradlew :app:assembleDebug :app:lintDebug
```

APK 位于 `app/build/outputs/apk/debug/app-debug.apk`。调试签名保存在本项目忽略的 `.local/android/` 中。后续覆盖安装须使用同一签名，以保留已导入的文章和进度。

## 通过 ADB 安装和传包

以下命令在 Mac 的本目录运行。先确认电视已开启并授权 ADB，运行 `adb devices` 查看目标设备序号。将命令中的 `<电视设备序号>` 替换为实际序号。

```sh
adb -s '<电视设备序号>' install -r app/build/outputs/apk/debug/app-debug.apk
```

安装后从电视应用列表打开「简单读」。每增加一份材料，在 Mac 上执行以下命令，把文件路径换成实际阅读包的完整路径。

```sh
./scripts/send-reading-pack.sh '<电视设备序号>' '/完整路径/KET阅读包.simpledu'
```

传包脚本会将文件完整写入电视版的私有收件箱。打开 App 或按「检查新阅读包」即可导入。脚本需要可执行的 `adb` 和支持 `run-as` 的电视固件。较新版本会替换同批次当前显示的内容，并从空白进度开始。卸载应用会移除电视端的文章和本地进度。
