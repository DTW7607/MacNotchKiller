# FullScreenTools

一个使用 AppKit、ScreenCaptureKit 和 macOS 私有 `CGVirtualDisplay` 接口实现的虚拟屏全屏控制工具。

程序启动时会创建一个与内置 Retina 屏幕逻辑尺寸、实际像素和刷新率一致的虚拟显示器，然后在内置屏幕上以无边框置顶窗口显示虚拟屏画面。鼠标和键盘会直接控制虚拟屏中的应用。

> `CGVirtualDisplay` 不是 Apple 公开 API，未来 macOS 更新可能导致接口失效，本程序不适合提交 Mac App Store。

## 系统要求

- macOS 13 或更高版本；主要验证环境为 macOS 26.5.1
- Apple Silicon Mac
- “屏幕与系统音频录制”权限
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

首次运行时，macOS 可能分别请求屏幕录制和辅助功能权限。如果授权后程序仍提示无权限，请退出程序，在以下位置允许终端或 `FullScreenTools`，然后重新运行：

```text
系统设置 → 隐私与安全性 → 屏幕与系统音频录制
系统设置 → 隐私与安全性 → 辅助功能
```

程序创建虚拟屏后会立即：

- 在内置屏幕显示虚拟屏内容。
- 把虚拟屏排列在物理屏幕联合区域的右下外角，只允许单个角点接触，利用 WindowServer 的显示器边界原生限制鼠标。
- Event Tap 不改写正常鼠标移动；仅在外部程序异常移动光标时吞掉越界点击并恢复到虚拟屏，避免误操作其他屏幕。
- 将窗口层级提高到菜单栏和 Dock 之上。
- 将菜单栏和 Dock 设置为完全不可用，而不是允许边缘唤出的自动隐藏。
- 捕获层使用 ScreenCaptureKit 的专用开关排除菜单栏；Dock 由应用级隐藏和快捷键拦截共同阻止唤出（不能排除整个 Dock 进程，否则桌面层会变黑）。
- 把普通键盘快捷键发送给虚拟屏当前应用。

按 `Control + Option + Command + Q` 可解除鼠标限制、销毁虚拟屏并退出程序。普通 `Command + Q` 会退出虚拟屏当前应用，而不是退出 FullScreenTools。
