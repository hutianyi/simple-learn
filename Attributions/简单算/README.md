# 简单算

一个面向 iPad 的离线心算训练 App，使用 SwiftUI 编写，适合个人和家庭使用。

## 功能

- 两位数加法、减法、乘法和整除除法
- 可自行选择两种、三种或四种题型混合练习，并在所选类型间尽量均衡分配
- 自定义数字键盘和每题独立计时
- App 进入后台时暂停当前题计时
- 完成后查看正确率、耗时和分题型表现
- 本地 JSON 保存历史记录、趋势图和单次练习详情
- 历史记录支持左滑删除，并默认展示最近 10 次

## 开发环境

- Xcode 26 或更高版本
- SwiftUI
- iPadOS 27.0
- 不需要服务器、账号或第三方 SDK

## 构建

打开 `SimpleSuan.xcodeproj`，选择 `SimpleSuan` target 后即可在模拟器或连接的 iPad 上运行。使用 Personal Team 签名时，可在 Xcode 的 Signing & Capabilities 中选择自己的团队。

单元测试使用串行模式运行：

```bash
xcodebuild -project SimpleSuan.xcodeproj -scheme SimpleSuan \
  -destination 'platform=iOS Simulator,name=iPad (A16)' \
  -parallel-testing-enabled NO test
```

## 数据

练习记录保存在 App Sandbox 的 `Application Support/SimpleSuan/data_v1.json`，写入时使用原子替换，并保留最近一次有效备份。练习完成后立即保存。

## 许可证

本项目以 MIT License 发布。
