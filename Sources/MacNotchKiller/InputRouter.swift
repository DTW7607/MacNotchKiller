import ApplicationServices
import CoreGraphics
import Foundation

private enum DockEdge {
    case left
    case right
    case bottom
}

protocol InputRouterDelegate: AnyObject {
    func inputRouterRequestedExit(_ router: InputRouter)
    func inputRouter(_ router: InputRouter, didFailWith message: String)
}

/// 输入安全层。
///
/// 正常鼠标移动完全交给 WindowServer。虚拟屏与物理屏在显示器坐标空间中
/// 只有角点接触、没有可穿越的共享边，因此系统会在虚拟屏边缘原生限制光标。本类不再累计
/// delta、改写坐标或在边缘反复 warp，只负责：
/// 1. 启动/退出时移动光标；
/// 2. 拦截退出快捷键和系统栏快捷键；
/// 3. 外部程序异常 warp 光标时吞掉越界点击并恢复到最后安全位置。
final class InputRouter {
    weak var delegate: InputRouterDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var virtualDisplayID: CGDirectDisplayID = kCGNullDirectDisplay
    private var virtualBounds: CGRect = .zero
    private var originalCursorLocation: CGPoint?
    private var lastSafeLocalLocation: CGPoint?
    private var dockEdge: DockEdge = .bottom
    private var suppressedMouseButtons: Set<Int64> = []
    private var exitKeyIsDown = false
    private var failureWasReported = false
    private let initialEdgeInset: CGFloat = 8
    private let dockTriggerInset: CGFloat = 4

    static func requestAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start(virtualDisplayID: CGDirectDisplayID, builtInDisplayID: CGDirectDisplayID) throws {
        stop(restoreCursor: false)

        let newVirtualBounds = CGDisplayBounds(virtualDisplayID)
        let builtInBounds = CGDisplayBounds(builtInDisplayID)
        guard newVirtualBounds.width > 0, newVirtualBounds.height > 0 else {
            throw InputRouterError.invalidVirtualBounds
        }

        self.virtualDisplayID = virtualDisplayID
        virtualBounds = newVirtualBounds
        dockEdge = Self.currentDockEdge()
        originalCursorLocation = CGEvent(source: nil)?.location

        let mask = Self.eventMask(for: [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .scrollWheel,
            .keyDown,
            .keyUp,
            .flagsChanged
        ])

        // HID tap 位于 WindowServer 路由事件之前。正常移动不做修改；只有坐标
        // 已经不在虚拟屏时才吞掉事件，保证点击不会先落到物理屏幕。
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            resetState()
            throw InputRouterError.eventTapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            resetState()
            throw InputRouterError.eventTapCreationFailed
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let original = originalCursorLocation ??
            CGPoint(x: builtInBounds.midX, y: builtInBounds.midY)
        let normalizedX = builtInBounds.contains(original)
            ? (original.x - builtInBounds.minX) / builtInBounds.width
            : 0.5
        let normalizedY = builtInBounds.contains(original)
            ? (original.y - builtInBounds.minY) / builtInBounds.height
            : 0.5
        let initialLocalLocation = clampLocal(
            CGPoint(
                x: normalizedX * virtualBounds.width,
                y: normalizedY * virtualBounds.height
            ),
            inset: initialEdgeInset
        )

        do {
            try moveCursorToVirtualDisplay(localLocation: initialLocalLocation)
        } catch {
            stop(restoreCursor: false)
            throw error
        }
    }

    func updateVirtualDisplay(_ displayID: CGDirectDisplayID) {
        let newBounds = CGDisplayBounds(displayID)
        guard newBounds.width > 0, newBounds.height > 0 else {
            reportFailure("虚拟显示器没有有效的全局坐标范围。")
            return
        }

        virtualDisplayID = displayID
        virtualBounds = newBounds
        dockEdge = Self.currentDockEdge()

        if let currentLocation = CGEvent(source: nil)?.location,
           contains(currentLocation) {
            lastSafeLocalLocation = localLocation(for: currentLocation)
            return
        }

        recoverCursor()
    }

    func stop(restoreCursor: Bool = true) {
        let locationToRestore = originalCursorLocation

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        resetState()

        if restoreCursor, let locationToRestore {
            _ = CGWarpMouseCursorPosition(locationToRestore)
            // Warp 会短暂抑制本地硬件事件；立即重新关联可避免退出后光标
            // 出现延迟、跳跃或第一段移动被忽略。
            _ = CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = {
        _,
        type,
        event,
        userInfo
    in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let router = Unmanaged<InputRouter>.fromOpaque(userInfo).takeUnretainedValue()
        return router.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard let eventTap else { return nil }
            CGEvent.tapEnable(tap: eventTap, enable: true)
            guard CGEvent.tapIsEnabled(tap: eventTap) else {
                reportFailure("全局输入安全层已停止且无法重新启用。")
                return nil
            }

            if let location = CGEvent(source: nil)?.location, !contains(location) {
                recoverCursor()
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let relevantFlags = event.flags.intersection([
                .maskControl,
                .maskAlternate,
                .maskCommand,
                .maskShift
            ])
            let exitFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

            if keyCode == 12, relevantFlags == exitFlags {
                if type == .keyDown, !exitKeyIsDown {
                    exitKeyIsDown = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.inputRouterRequestedExit(self)
                    }
                } else if type == .keyUp {
                    exitKeyIsDown = false
                }
                return nil
            }

            // Control+F3 聚焦 Dock；Command+Option+D 切换 Dock。菜单栏的
            // Control+F2 不再拦截，保持虚拟屏菜单栏的系统默认行为。
            let focusesDock = event.flags.contains(.maskControl) && keyCode == 99
            let togglesDock = keyCode == 2 &&
                relevantFlags == [.maskAlternate, .maskCommand]
            if focusesDock || togglesDock {
                return nil
            }
        }

        if Self.pointerEventTypes.contains(type), !refreshVirtualBounds() {
            // 显示器消失或处于无效重排状态时，鼠标事件全部失败关闭。
            return nil
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard contains(event.location) else {
                // 正常硬件移动不可能跨越隔离空隙；出现越界说明显示器被重排
                // 或其他进程 warp 了光标。吞掉该事件并恢复，不改写正常事件。
                recoverCursor()
                return nil
            }
            // 只钳制垂直于 Dock 的坐标，保留平行方向的连续位移。这样既不
            // 触发 Dock，光标沿屏幕底边/侧边移动时也不会因整条事件被丢弃而卡顿。
            if isInsideDockTrigger(event.location) {
                event.location = locationOutsideDockTrigger(event.location)
            }
            lastSafeLocalLocation = localLocation(for: event.location)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = mouseButtonNumber(for: type, event: event)
            guard contains(event.location) else {
                suppressedMouseButtons.insert(button)
                recoverCursor()
                return nil
            }
            if isInsideDockTrigger(event.location) {
                event.location = locationOutsideDockTrigger(event.location)
            }
            lastSafeLocalLocation = localLocation(for: event.location)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = mouseButtonNumber(for: type, event: event)
            if suppressedMouseButtons.remove(button) != nil {
                return nil
            }
            // 如果按下起点在应用内，释放事件必须继续投递，即使拖拽期间进入
            // Dock 触发区，否则目标应用会永久停留在按下/拖拽状态。
            guard contains(event.location) else {
                recoverCursor()
                return nil
            }
            if isInsideDockTrigger(event.location) {
                event.location = locationOutsideDockTrigger(event.location)
            }
            lastSafeLocalLocation = localLocation(for: event.location)

        case .scrollWheel:
            guard contains(event.location) else {
                recoverCursor()
                return nil
            }
            if isInsideDockTrigger(event.location) {
                event.location = locationOutsideDockTrigger(event.location)
            }
            lastSafeLocalLocation = localLocation(for: event.location)

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func moveCursorToVirtualDisplay(localLocation: CGPoint) throws {
        guard virtualDisplayID != kCGNullDirectDisplay else {
            throw InputRouterError.invalidVirtualBounds
        }

        let safeLocalLocation = clampLocal(localLocation, inset: initialEdgeInset)
        let moveResult = CGDisplayMoveCursorToPoint(
            virtualDisplayID,
            safeLocalLocation
        )
        guard moveResult == .success else {
            throw InputRouterError.cursorMoveFailed(moveResult)
        }

        let associationResult = CGAssociateMouseAndMouseCursorPosition(1)
        guard associationResult == .success else {
            throw InputRouterError.cursorMoveFailed(associationResult)
        }
        lastSafeLocalLocation = safeLocalLocation
    }

    private func recoverCursor() {
        let fallback = lastSafeLocalLocation ??
            CGPoint(x: virtualBounds.width / 2, y: virtualBounds.height / 2)
        do {
            try moveCursorToVirtualDisplay(localLocation: fallback)
        } catch {
            reportFailure(error.localizedDescription)
        }
    }

    private func refreshVirtualBounds() -> Bool {
        guard virtualDisplayID != kCGNullDirectDisplay else { return false }
        let currentBounds = CGDisplayBounds(virtualDisplayID)
        guard currentBounds.width > 0, currentBounds.height > 0 else {
            reportFailure("虚拟显示器已不可用，鼠标事件已停止投递。")
            return false
        }
        virtualBounds = currentBounds
        return true
    }

    private func contains(_ globalLocation: CGPoint) -> Bool {
        virtualBounds.contains(globalLocation)
    }

    private func localLocation(for globalLocation: CGPoint) -> CGPoint {
        CGPoint(
            x: globalLocation.x - virtualBounds.minX,
            y: globalLocation.y - virtualBounds.minY
        )
    }

    private func isInsideDockTrigger(_ globalLocation: CGPoint) -> Bool {
        guard contains(globalLocation) else {
            return false
        }
        switch dockEdge {
        case .left:
            return globalLocation.x < virtualBounds.minX + dockTriggerInset
        case .right:
            return globalLocation.x >= virtualBounds.maxX - dockTriggerInset
        case .bottom:
            return globalLocation.y >= virtualBounds.maxY - dockTriggerInset
        }
    }

    private func locationOutsideDockTrigger(_ location: CGPoint) -> CGPoint {
        var result = location
        switch dockEdge {
        case .left:
            result.x = virtualBounds.minX + dockTriggerInset
        case .right:
            result.x = virtualBounds.maxX - dockTriggerInset
        case .bottom:
            result.y = virtualBounds.maxY - dockTriggerInset
        }
        return result
    }

    private func mouseButtonNumber(
        for type: CGEventType,
        event: CGEvent
    ) -> Int64 {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            return 0
        case .rightMouseDown, .rightMouseUp:
            return 1
        default:
            return event.getIntegerValueField(.mouseEventButtonNumber)
        }
    }

    private func clampLocal(_ point: CGPoint, inset: CGFloat) -> CGPoint {
        let maximumX = max(inset, virtualBounds.width - inset)
        let maximumY = max(inset, virtualBounds.height - inset)
        return CGPoint(
            x: min(max(point.x, inset), maximumX),
            y: min(max(point.y, inset), maximumY)
        )
    }

    private func reportFailure(_ message: String) {
        guard !failureWasReported else { return }
        failureWasReported = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.inputRouter(self, didFailWith: message)
        }
    }

    private func resetState() {
        virtualDisplayID = kCGNullDirectDisplay
        virtualBounds = .zero
        originalCursorLocation = nil
        lastSafeLocalLocation = nil
        dockEdge = .bottom
        suppressedMouseButtons.removeAll()
        exitKeyIsDown = false
        failureWasReported = false
    }

    private static func eventMask(for types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private static let pointerEventTypes: Set<CGEventType> = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
        .scrollWheel
    ]

    private static func currentDockEdge() -> DockEdge {
        let orientation = UserDefaults.standard
            .persistentDomain(forName: "com.apple.dock")?["orientation"] as? String
        switch orientation {
        case "left":
            return .left
        case "right":
            return .right
        default:
            return .bottom
        }
    }
}

enum InputRouterError: LocalizedError {
    case invalidVirtualBounds
    case eventTapCreationFailed
    case cursorMoveFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .invalidVirtualBounds:
            return "虚拟显示器没有有效的全局坐标范围。"
        case .eventTapCreationFailed:
            return "无法创建全局输入安全层。请在系统设置中允许辅助功能权限后重新运行。"
        case let .cursorMoveFailed(error):
            return "无法将鼠标移动到隔离的虚拟显示器（CoreGraphics 错误 \(error.rawValue)）。"
        }
    }
}
