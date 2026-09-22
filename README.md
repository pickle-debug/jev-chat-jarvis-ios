# Jarvis iOS

UIKit Home 页面，参考 Visyn Demo，提供系统录屏开关、画中画开关、录屏状态和收帧计数。

业务接入架构见 [iOS 业务架构设计](docs/architecture/ios-business-architecture.md)，包括 OCR、跨屏会话合并、BYOK、语义分析、PiP 和 Jarvis 自定义键盘。

## 运行

用 Xcode 打开 `jev-chat-jarvis-ios.xcodeproj`，选择 `jev-chat-jarvis-ios` scheme。
项目通过本地 Swift Package 引用 `../Visyn`，请保持两个仓库位于同一级目录。
主 App 链接 `VisynCapture`，嵌入的 `JarvisBroadcastExtension` 链接 `VisynBroadcast`。

主 App 与扩展共用项目级配置：

- `VISYN_APP_BUNDLE_IDENTIFIER`：`com.heself.jev-chat-jarvis-ios`
- `VISYN_APP_GROUP`：`group.$(VISYN_APP_BUNDLE_IDENTIFIER)`
- 扩展 Bundle ID：`$(VISYN_APP_BUNDLE_IDENTIFIER).BroadcastExtension`

真机运行前，在 Xcode Signing & Capabilities / Apple Developer 中为两个 Target
配置同一个开发团队，并为两端 App ID 启用同一个已注册的 App Group。
项目已包含两端的 entitlement、Info.plist 参数和主 App 的 Audio 后台模式。
如果使用其他 App Group，在项目 Build Settings 中修改 `VISYN_APP_GROUP`。

## 验证

```sh
xcodebuild -project jev-chat-jarvis-ios.xcodeproj \
  -scheme jev-chat-jarvis-ios -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

模拟器可验证页面和构建；ReplayKit 授权、跨 App 采集、后台与画中画需要真机验证。
真机检查：开始录屏 → 在系统面板确认 → 收帧数增加 → 开关画中画 →
切换其他 App → 返回 → 停止录屏 → 确认状态与计数复位；取消授权时应保持待机。
页面仅显示帧数与尺寸，不保存或记录屏幕图像。
