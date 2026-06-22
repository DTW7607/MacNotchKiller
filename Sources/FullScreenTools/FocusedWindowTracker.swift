import AppKit
import ApplicationServices
import CoreGraphics

private let fstAXFullScreenAttribute = "AXFullScreen" as CFString

@MainActor
struct FocusedWindowHandle {
    let element: AXUIElement
    let ownerPID: pid_t
    let title: String?

    func focus() {
        NSRunningApplication(processIdentifier: ownerPID)?.activate(
            options: [.activateIgnoringOtherApps]
        )
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func moveToDisplay(_ displayID: CGDirectDisplayID) throws {
        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            throw FocusedWindowError.invalidTargetDisplay
        }

        var isPositionSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXPositionAttribute as CFString,
            &isPositionSettable
        )
        guard settableResult == .success, isPositionSettable.boolValue else {
            throw FocusedWindowError.windowIsNotMovable(title)
        }

        let windowSize = readSize() ?? CGSize(
            width: displayBounds.width * 0.7,
            height: displayBounds.height * 0.7
        )
        var targetPosition = CGPoint(
            x: displayBounds.minX + max(0, (displayBounds.width - windowSize.width) / 2),
            y: displayBounds.minY + max(0, (displayBounds.height - windowSize.height) / 2)
        )
        guard let positionValue = AXValueCreate(.cgPoint, &targetPosition) else {
            throw FocusedWindowError.positionEncodingFailed
        }

        let moveResult = AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            positionValue
        )
        guard moveResult == .success else {
            throw FocusedWindowError.moveFailed(title, moveResult)
        }

        // 保证键盘焦点仍属于被移动的应用。CaptureWindow 不激活且忽略鼠标，
        // 后续透传窗口出现时不会抢走目标窗口的前台状态。
        focus()
    }

    func enterFullScreen() throws {
        var isFullScreenSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            fstAXFullScreenAttribute,
            &isFullScreenSettable
        )

        if settableResult == .success, isFullScreenSettable.boolValue {
            let result = AXUIElementSetAttributeValue(
                element,
                fstAXFullScreenAttribute,
                kCFBooleanTrue
            )
            guard result == .success else {
                throw FocusedWindowError.fullScreenFailed(title, result)
            }
            return
        }

        // 少数应用不公开 AXFullScreen 可写属性，但会公开标题栏的原生
        // 全屏按钮。按下该按钮仍是系统原生全屏，而不是简单最大化。
        if let buttonValue = FocusedWindowTracker.copyAttribute(
            kAXFullScreenButtonAttribute as CFString,
            from: element
        ), CFGetTypeID(buttonValue) == AXUIElementGetTypeID() {
            let button = buttonValue as! AXUIElement
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            guard result == .success else {
                throw FocusedWindowError.fullScreenFailed(title, result)
            }
            return
        }

        throw FocusedWindowError.fullScreenUnsupported(title)
    }

    private func readSize() -> CGSize? {
        guard let value = FocusedWindowTracker.copyAttribute(
            kAXSizeAttribute as CFString,
            from: element
        ), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return size
    }
}

@MainActor
enum FocusedWindowTracker {
    static func currentFocusedWindow(
        excludingProcessID: pid_t
    ) -> FocusedWindowHandle? {
        let systemWide = AXUIElementCreateSystemWide()
        let focusedApplication: AXUIElement

        if let applicationValue = copyAttribute(
            kAXFocusedApplicationAttribute as CFString,
            from: systemWide
        ), CFGetTypeID(applicationValue) == AXUIElementGetTypeID() {
            focusedApplication = applicationValue as! AXUIElement
        } else if let frontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier {
            focusedApplication = AXUIElementCreateApplication(frontmostPID)
        } else {
            return nil
        }

        guard let windowValue = copyAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: focusedApplication
        ), CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let window = windowValue as! AXUIElement
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(window, &ownerPID) == .success,
              ownerPID != 0,
              ownerPID != excludingProcessID else {
            return nil
        }

        if let role = copyAttribute(
            kAXRoleAttribute as CFString,
            from: window
        ) as? String, role != (kAXWindowRole as String) {
            return nil
        }

        let title = copyAttribute(
            kAXTitleAttribute as CFString,
            from: window
        ) as? String
        return FocusedWindowHandle(
            element: window,
            ownerPID: ownerPID,
            title: title
        )
    }

    /// 把 WindowServer 命中的可见窗口映射到同一应用公开的 AXWindow。
    /// CGWindowList 提供可靠的前后层级，AXWindow 则用于后续移动和原生全屏。
    static func window(
        ownerPID: pid_t,
        matching targetBounds: CGRect,
        title targetTitle: String?,
        containing location: CGPoint
    ) -> FocusedWindowHandle? {
        let application = AXUIElementCreateApplication(ownerPID)
        guard let windowsValue = copyAttribute(
            kAXWindowsAttribute as CFString,
            from: application
        ), CFGetTypeID(windowsValue) == CFArrayGetTypeID(),
        let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        var bestMatch: (element: AXUIElement, title: String?, score: CGFloat)?
        for window in windows {
            if let role = copyAttribute(
                kAXRoleAttribute as CFString,
                from: window
            ) as? String, role != (kAXWindowRole as String) {
                continue
            }
            if let minimized = copyAttribute(
                kAXMinimizedAttribute as CFString,
                from: window
            ) as? Bool, minimized {
                continue
            }
            guard let bounds = bounds(of: window),
                  bounds.insetBy(dx: -2, dy: -2).contains(location) else {
                continue
            }

            let title = copyAttribute(
                kAXTitleAttribute as CFString,
                from: window
            ) as? String
            var score = abs(bounds.minX - targetBounds.minX) +
                abs(bounds.minY - targetBounds.minY) +
                abs(bounds.width - targetBounds.width) +
                abs(bounds.height - targetBounds.height)
            if let targetTitle, !targetTitle.isEmpty, title == targetTitle {
                score -= 10_000
            }

            if bestMatch == nil || score < bestMatch!.score {
                bestMatch = (window, title, score)
            }
        }

        guard let bestMatch else { return nil }
        return FocusedWindowHandle(
            element: bestMatch.element,
            ownerPID: ownerPID,
            title: bestMatch.title
        )
    }

    private static func bounds(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(
            kAXPositionAttribute as CFString,
            from: element
        ), CFGetTypeID(positionValue) == AXValueGetTypeID(),
        let sizeValue = copyAttribute(
            kAXSizeAttribute as CFString,
            from: element
        ), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetType(sizeAXValue) == .cgSize else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    static func copyAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return value
    }
}

enum FocusedWindowError: LocalizedError {
    case noFocusedWindow
    case selectionMonitorUnavailable
    case selectionCancelled
    case invalidTargetDisplay
    case windowIsNotMovable(String?)
    case positionEncodingFailed
    case moveFailed(String?, AXError)
    case fullScreenUnsupported(String?)
    case fullScreenFailed(String?, AXError)

    var errorDescription: String? {
        switch self {
        case .noFocusedWindow:
            return "没有选择可移动的窗口。"
        case .selectionMonitorUnavailable:
            return "无法启动全局窗口选择器。请确认 FullScreenTools 已获得辅助功能权限。"
        case .selectionCancelled:
            return "窗口选择已取消。"
        case .invalidTargetDisplay:
            return "虚拟显示器没有有效的目标坐标。"
        case let .windowIsNotMovable(title):
            return "焦点窗口“\(title ?? "未命名窗口")”不允许通过辅助功能移动。"
        case .positionEncodingFailed:
            return "无法生成焦点窗口的目标位置。"
        case let .moveFailed(title, error):
            return "无法将焦点窗口“\(title ?? "未命名窗口")”移动到虚拟屏（AXError \(error.rawValue)）。"
        case let .fullScreenUnsupported(title):
            return "焦点窗口“\(title ?? "未命名窗口")”不支持 macOS 原生全屏。"
        case let .fullScreenFailed(title, error):
            return "焦点窗口“\(title ?? "未命名窗口")”进入原生全屏失败（AXError \(error.rawValue)）。"
        }
    }
}
