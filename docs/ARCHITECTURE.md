# Architecture

[简体中文](ARCHITECTURE.zh-CN.md)

## Goal

MacNotchKiller does not reimplement the target application. Its goal is to let the target app's own native fullscreen surface use the full built-in panel on a notched MacBook, without modifying the target app.

Core constraints:

- The target app keeps ownership of the window and input focus.
- The image path does not perform video encoding.
- Normal mouse movement remains handled by WindowServer.
- Any failure must be able to stop input interception and destroy the virtual display.

## Startup flow

1. Check `CGVirtualDisplay` runtime availability and Accessibility permission.
2. `WindowSelector` hit-tests the window under the mouse using WindowServer ordering and shows the candidate with a blue outline.
3. After click confirmation, map the CoreGraphics window to the corresponding Accessibility window.
4. `VirtualDisplayController` creates a virtual display matching the built-in panel.
5. Wait until the display is Online, Active, and visible through `NSScreen.screens`.
6. Arrange the virtual display at an isolated corner outside the physical display union.
7. Move the target window and trigger macOS native fullscreen.
8. `CaptureSession` starts `CGDisplayStream` for the virtual display ID.
9. `CaptureWindowController` shows the Metal pass-through layer on the built-in display.
10. `InputRouter` places the cursor inside the virtual display and installs the input safety boundary.

## Module responsibilities

| Module | Responsibility |
| --- | --- |
| `AppDelegate` | Lifecycle, state machine, resource creation, and failure cleanup |
| `WindowSelector` | Hover hit-testing, blue outline, click confirmation |
| `FocusedWindowTracker` | Accessibility window matching, movement, and native fullscreen |
| `VirtualDisplayController` | Virtual display creation, mode validation, layout, and teardown |
| `CaptureSession` | `CGDisplayStream` lifecycle and frame callbacks |
| `CaptureWindowController` | Built-in-screen overlay window and Metal render target |
| `InputRouter` | Event Tap, cursor restoration, Dock boundary, and recovery shortcut |
| `VirtualDisplayBridge` | Objective-C private runtime bridge and C display-stream wrapper |

## Image data path

```text
Target app
  → WindowServer composites on the virtual display
  → CGDisplayStream callback provides an IOSurface
  → Metal maps the IOSurface as a texture
  → Blit into the CAMetalLayer drawable
  → Built-in display
```

The `IOSurface` is kept alive through a use count until GPU commands complete, preventing WindowServer from reusing the buffer too early.

## Coordinate domains

The project handles three coordinate domains:

- CoreGraphics global display coordinates: top-left origin.
- Accessibility window coordinates: aligned with the CoreGraphics display space.
- AppKit screen and window coordinates: bottom-left origin.

The window-selection outline must convert the vertical axis from CoreGraphics to AppKit before display. Input routing always uses CoreGraphics global coordinates to avoid mixing coordinate domains in multi-display layouts.

## Failure handling

Startup and runtime failures use the same cleanup order:

1. Stop Event Tap and input restrictions.
2. Stop the display stream and release frame callbacks.
3. Close the pass-through window.
4. Restore AppKit presentation options.
5. Destroy the virtual display.
6. Restore the previous frontmost app and cursor position.

## API risks

- `CGVirtualDisplay` has no public stability guarantee.
- `CGDisplayStream` has been marked obsolete by Apple.
- Accessibility behavior depends on the target app's implementation.
- WindowServer behavior around display snapping, Spaces, and the Dock may change across macOS versions.

Changes around these boundaries must be validated on real notched hardware. A successful compile does not prove runtime compatibility.
