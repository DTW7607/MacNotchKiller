# 架构说明

[English](ARCHITECTURE.md) | 简体中文

## 目标

MacNotchKiller 的目标不是重新实现目标应用，而是在不修改目标应用的前提下，让其原生全屏画面使用带刘海 MacBook 的整块内置面板。

核心约束：

- 目标应用仍然拥有窗口和输入焦点。
- 画面链路不进行视频编码。
- 正常鼠标移动由 WindowServer 处理。
- 任意失败都必须能够停止输入拦截并销毁虚拟显示器。

## 启动流程

1. 检查 `CGVirtualDisplay` 运行时能力和辅助功能权限。
2. `WindowSelector` 按 WindowServer 层级命中鼠标下方窗口，并用蓝色边框显示候选。
3. 点击确认后，将 CG 窗口映射为对应的 Accessibility 窗口。
4. `VirtualDisplayController` 创建与内置屏尺寸匹配的虚拟显示器。
5. 等待显示器进入 Online、Active 状态并出现在 `NSScreen.screens`。
6. 将虚拟屏排列到物理显示器联合区域的隔离角点。
7. 移动目标窗口并触发 macOS 原生全屏。
8. `CaptureSession` 按虚拟显示器 ID 启动 `CGDisplayStream`。
9. `CaptureWindowController` 在内置屏显示 Metal 透传层。
10. `InputRouter` 将光标放入虚拟屏并建立输入安全边界。

## 模块职责

| 模块 | 职责 |
| --- | --- |
| `AppDelegate` | 生命周期、状态机、资源创建和失败清理 |
| `WindowSelector` | 悬停命中、蓝色边框、点击确认 |
| `FocusedWindowTracker` | Accessibility 窗口匹配、移动和原生全屏 |
| `VirtualDisplayController` | 虚拟显示器创建、模式验证、布局和销毁 |
| `CaptureSession` | `CGDisplayStream` 生命周期和帧回调 |
| `CaptureWindowController` | 内置屏置顶窗口和 Metal 渲染目标 |
| `InputRouter` | Event Tap、光标恢复、Dock 边界和退出快捷键 |
| `VirtualDisplayBridge` | Objective-C 私有运行时桥接和 C 显示流封装 |

## 画面数据路径

```text
目标应用
  → WindowServer 在虚拟显示器上合成
  → CGDisplayStream 回调 IOSurface
  → Metal 纹理映射
  → Blit 到 CAMetalLayer drawable
  → 内置显示器
```

`IOSurface` 在 GPU 命令完成前通过使用计数保持有效，避免 WindowServer 过早复用缓冲区。

## 坐标域

项目同时处理三类坐标：

- CoreGraphics 显示器全局坐标：左上原点。
- Accessibility 窗口坐标：与 CoreGraphics 显示空间一致。
- AppKit 屏幕与窗口坐标：左下原点。

窗口选择边框显示前必须完成 CoreGraphics 到 AppKit 的纵轴转换。输入路由则始终使用 CoreGraphics 全局坐标，避免多屏排列时混用坐标域。

## 失败处理

启动和运行阶段都遵循同一清理顺序：

1. 停止 Event Tap 和输入限制。
2. 停止显示流并释放帧回调。
3. 关闭透传窗口。
4. 恢复 AppKit presentation options。
5. 销毁虚拟显示器。
6. 恢复原前台应用和光标位置。

## API 风险

- `CGVirtualDisplay` 没有公开稳定性保证。
- `CGDisplayStream` 已被 Apple 标记为 obsolete。
- Accessibility 能力由目标应用实现决定。
- WindowServer 的显示器吸附、Space 和 Dock 行为可能随系统更新变化。

涉及这些边界的改动必须在真实带刘海设备上验证；仅通过编译不能证明运行时兼容。
