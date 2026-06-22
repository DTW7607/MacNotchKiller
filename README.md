# FullScreenTools

一个使用 AppKit、Metal、CoreGraphics `CGDisplayStream` 和 macOS 私有 `CGVirtualDisplay` 接口实现的虚拟屏全屏控制工具。

程序启动时先进入窗口选择模式：鼠标悬停的可选窗口会显示蓝色外框，点击确认后，程序创建一个与内置 Retina 屏幕逻辑尺寸、实际像素和刷新率一致的虚拟显示器。选中的窗口移入虚拟屏后，程序才在内置屏幕上显示无边框置顶透传窗口并接管键鼠。

> `CGVirtualDisplay` 不是 Apple 公开 API，未来 macOS 更新可能导致接口失效，本程序不适合提交 Mac App Store。

## 系统要求

- macOS 13 或更高版本；主要验证环境为 macOS 26.5.1
- Apple Silicon Mac
- “辅助功能”权限

## 构建

```bash
swift build -c release
```

生成的可执行文件位于：

```text
.build/release/FullScreenTools
```

## 运行

```bash
.build/release/FullScreenTools
```

首次运行时，macOS 会请求辅助功能权限。如果授权后程序仍提示无权限，请退出程序，在以下位置允许终端或 `FullScreenTools`，然后重新运行：

```text
系统设置 → 隐私与安全性 → 辅助功能
```

启动流程：

- 虚拟屏创建前进入主动选择模式；鼠标悬停在可选窗口上时显示蓝色外框。
- 点击带蓝色外框的窗口确认选择；该次点击会被拦截，不会误触窗口内控件。
- 创建虚拟屏后，将选中的窗口移动到虚拟屏并进入 macOS 原生全屏。
- 移动完成后才在内置屏幕显示虚拟屏内容并接管鼠标。
- 只有启动选择阶段会临时枚举可见窗口并匹配辅助功能窗口；画面捕获不使用 ScreenCaptureKit，也不枚举或排除任何窗口。程序按虚拟显示器 ID 从 `CGDisplayStream` 回调直接取得 WindowServer 的 `IOSurface`，并用 Metal 映射到内置屏透传窗口。
- 把虚拟屏排列在物理屏幕联合区域的右下外角，只允许单个角点接触，利用 WindowServer 的显示器边界原生限制鼠标。
- Event Tap 不改写正常鼠标移动；仅在外部程序异常移动光标时吞掉越界点击并恢复到虚拟屏，避免误操作其他屏幕。
- 将窗口层级提高到菜单栏和 Dock 之上。
- 虚拟屏菜单栏保持 macOS 默认显示、隐藏、点击和快捷键行为，程序不做过滤。
- 虚拟屏 Dock 由原生全屏先隐藏；HID 输入层阻止鼠标进入用户配置的 Dock 边缘触发区，并拦截 `Control+F3` 和 `Command+Option+D`，使 Dock 无法被常规输入唤出。
- 把普通键盘快捷键发送给虚拟屏当前应用。

按 `Control + Option + Command + Q` 可解除鼠标限制、销毁虚拟屏并退出程序。普通 `Command + Q` 会退出虚拟屏当前应用，而不是退出 FullScreenTools。

## 关于系统录屏标识

`CGVirtualDisplay` 本身只创建显示输出端点，不公开可读取的 framebuffer。本程序现在使用的 `CGDisplayStream` 是能直接取得该显示器 `IOSurface` 的最低层系统接口，但 Apple 从 macOS 15 起已将它标记为 obsolete，并建议改用 ScreenCaptureKit。程序通过运行时符号兼容当前系统，不再主动请求屏幕录制权限；macOS 是否仍把此接口归类为屏幕采集、是否显示系统隐私标识，最终由 WindowServer/TCC 决定，应用无法强制关闭。
