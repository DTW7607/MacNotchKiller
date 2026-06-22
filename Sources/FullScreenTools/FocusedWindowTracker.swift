import AppKit
import ApplicationServices
import CoreGraphics

private let fstAXFullScreenAttribute = "AXFullScreen" as CFString

@MainActor
struct FocusedWindowHandle {
    let element: AXUIElement
    let ownerPID: pid_t
    let title: String?

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
        NSRunningApplication(processIdentifier: ownerPID)?.activate(
            options: [.activateIgnoringOtherApps]
        )
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
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
    /// 在指定时间内持续记录最后一个有效焦点窗口。程序自身永远不会成为候选。
    static func latestFocusedWindow(
        forNanoseconds duration: UInt64,
        excludingProcessID: pid_t
    ) async throws -> FocusedWindowHandle {
        let pollingInterval: UInt64 = 100_000_000
        var elapsed: UInt64 = 0
        var latest = currentFocusedWindow(excludingProcessID: excludingProcessID)

        while elapsed < duration {
            try Task.checkCancellation()
            if let current = currentFocusedWindow(
                excludingProcessID: excludingProcessID
            ) {
                latest = current
            }
            let sleepDuration = min(pollingInterval, duration - elapsed)
            try await Task.sleep(nanoseconds: sleepDuration)
            elapsed += sleepDuration
        }

        if let current = currentFocusedWindow(excludingProcessID: excludingProcessID) {
            latest = current
        }
        guard let latest else {
            throw FocusedWindowError.noFocusedWindow
        }
        return latest
    }

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
    case invalidTargetDisplay
    case windowIsNotMovable(String?)
    case positionEncodingFailed
    case moveFailed(String?, AXError)
    case fullScreenUnsupported(String?)
    case fullScreenFailed(String?, AXError)

    var errorDescription: String? {
        switch self {
        case .noFocusedWindow:
            return "3 秒内没有检测到可移动的焦点窗口。请保持目标窗口处于前台后重新运行。"
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
