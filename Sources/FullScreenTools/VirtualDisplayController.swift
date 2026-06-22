import AppKit
import CoreGraphics
import VirtualDisplayBridge

enum VirtualDisplayError: LocalizedError {
    case unsupported
    case creationFailed(String)
    case registrationTimedOut
    case modeMismatch(expected: String, actual: String)
    case positioningFailed(CGError)
    case isolationFailed

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "当前 macOS 不支持所需的 CGVirtualDisplay 私有接口。"
        case let .creationFailed(message):
            return message
        case .registrationTimedOut:
            return "虚拟显示器创建后没有及时出现在系统显示器列表中。"
        case let .modeMismatch(expected, actual):
            return "虚拟显示器分辨率不匹配。期望：\(expected)，实际：\(actual)。"
        case let .positioningFailed(error):
            return "无法临时排列虚拟显示器（CoreGraphics 错误 \(error.rawValue)）。"
        case .isolationFailed:
            return "WindowServer 未能保持虚拟显示器的角点隔离布局，已停止运行以避免鼠标进入其他屏幕。"
        }
    }
}

@MainActor
final class VirtualDisplayController {
    private(set) var displayID: CGDirectDisplayID?
    var unexpectedTerminationHandler: (() -> Void)?

    private var virtualDisplay: FSTVirtualDisplay?

    static var isSupported: Bool {
        FSTVirtualDisplay.isSupported
    }

    func create(matching profile: DisplayProfile) throws {
        destroy()

        let display: FSTVirtualDisplay
        do {
            display = try FSTVirtualDisplay(
                name: "FullScreenTools Virtual Display",
                pixelWidth: UInt32(profile.pixelWidth),
                pixelHeight: UInt32(profile.pixelHeight),
                logicalWidth: UInt32(profile.logicalWidth),
                logicalHeight: UInt32(profile.logicalHeight),
                refreshRate: profile.refreshRate,
                physicalSize: profile.physicalSize
            )
        } catch {
            throw VirtualDisplayError.creationFailed(
                error.localizedDescription
            )
        }

        display.terminationHandler = { [weak self] in
            self?.unexpectedTerminationHandler?()
        }
        virtualDisplay = display
        displayID = display.displayID
    }

    func waitUntilReady(
        matching profile: DisplayProfile,
        timeoutNanoseconds: UInt64 = 15_000_000_000
    ) async throws -> NSScreen? {
        guard let displayID else {
            throw VirtualDisplayError.creationFailed("虚拟显示器没有有效 ID。")
        }

        let interval: UInt64 = 100_000_000
        var elapsed: UInt64 = 0

        while elapsed < timeoutNanoseconds {
            if CGDisplayIsOnline(displayID) != 0, CGDisplayIsActive(displayID) != 0 {
                if let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
                    try await selectAndValidateMode(profile: profile, screen: screen)
                    return screen
                }
            }

            try await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }

        throw VirtualDisplayError.registrationTimedOut
    }

    /// 将虚拟屏放到物理屏幕联合区域的右下外角，只保留一个角点接触。
    ///
    /// 当前 WindowServer 会把完全断开的显示器自动吸附回相邻边，但允许两个
    /// 显示器只在角点接触。鼠标跨屏需要具有长度的共享边；单个角点不会形成
    /// 可穿越通道，因此仍由 WindowServer 原生限制光标。
    func positionAtIsolatedCorner(
        ofAllDisplaysAligningWith builtInDisplayID: CGDirectDisplayID
    ) throws {
        guard let displayID else { return }

        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
            throw VirtualDisplayError.positioningFailed(.failure)
        }

        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        let listResult = CGGetOnlineDisplayList(count, &displays, &count)
        guard listResult == .success else {
            throw VirtualDisplayError.positioningFailed(listResult)
        }

        let physicalDisplays = Array(
            displays.prefix(Int(count)).filter { $0 != displayID }
        )
        let physicalBounds = physicalDisplays.map(CGDisplayBounds)
        let rightEdge = physicalBounds
            .map(\.maxX)
            .max() ?? CGDisplayBounds(builtInDisplayID).maxX
        // 选择所有最右侧显示器中最低的右下角。这样目标点确实属于一个物理
        // 显示器，同时其他物理屏都不会与虚拟屏形成纵向共享边。
        let rightmostBottomEdge = physicalBounds
            .filter { abs($0.maxX - rightEdge) < 0.5 }
            .map(\.maxY)
            .max() ?? CGDisplayBounds(builtInDisplayID).maxY
        let targetOrigin = CGPoint(
            x: ceil(rightEdge),
            y: ceil(rightmostBottomEdge)
        )
        let currentOrigin = CGDisplayBounds(displayID).origin

        if currentOrigin != targetOrigin {
            var configuration: CGDisplayConfigRef?
            let beginResult = CGBeginDisplayConfiguration(&configuration)
            guard beginResult == .success, let configuration else {
                throw VirtualDisplayError.positioningFailed(beginResult)
            }

            let unmirrorResult = CGConfigureDisplayMirrorOfDisplay(
                configuration,
                displayID,
                kCGNullDirectDisplay
            )
            guard unmirrorResult == .success else {
                CGCancelDisplayConfiguration(configuration)
                throw VirtualDisplayError.positioningFailed(unmirrorResult)
            }

            let originResult = CGConfigureDisplayOrigin(
                configuration,
                displayID,
                Int32(clamping: Int(targetOrigin.x)),
                Int32(clamping: Int(targetOrigin.y))
            )
            guard originResult == .success else {
                CGCancelDisplayConfiguration(configuration)
                throw VirtualDisplayError.positioningFailed(originResult)
            }

            let completeResult = CGCompleteDisplayConfiguration(configuration, .forAppOnly)
            guard completeResult == .success else {
                throw VirtualDisplayError.positioningFailed(completeResult)
            }
        }

        // CoreGraphics 可能接受配置但调整最终坐标。必须检查实际结果，并确认
        // 没有面积重叠或具有长度的共享边；单点接触是唯一允许的连接。
        let positionedBounds = CGDisplayBounds(displayID)
        let originMatches = abs(positionedBounds.minX - targetOrigin.x) < 0.5 &&
            abs(positionedBounds.minY - targetOrigin.y) < 0.5
        let hasUnsafeContact = physicalBounds.contains { bounds in
            let intersection = positionedBounds.intersection(bounds)
            let overlapsArea = !intersection.isNull &&
                intersection.width > 0.5 && intersection.height > 0.5
            let verticalOverlap = min(positionedBounds.maxY, bounds.maxY) -
                max(positionedBounds.minY, bounds.minY)
            let horizontalOverlap = min(positionedBounds.maxX, bounds.maxX) -
                max(positionedBounds.minX, bounds.minX)
            let sharesVerticalEdge = (
                abs(positionedBounds.minX - bounds.maxX) < 0.5 ||
                    abs(positionedBounds.maxX - bounds.minX) < 0.5
            ) && verticalOverlap > 0.5
            let sharesHorizontalEdge = (
                abs(positionedBounds.minY - bounds.maxY) < 0.5 ||
                    abs(positionedBounds.maxY - bounds.minY) < 0.5
            ) && horizontalOverlap > 0.5
            return overlapsArea || sharesVerticalEdge || sharesHorizontalEdge
        }
        guard originMatches, !hasUnsafeContact else {
            throw VirtualDisplayError.isolationFailed
        }
    }

    func destroy() {
        virtualDisplay?.terminationHandler = nil
        virtualDisplay = nil
        displayID = nil
    }

    private func selectAndValidateMode(
        profile: DisplayProfile,
        screen: NSScreen?
    ) async throws {
        guard let displayID else { return }

        if !modeMatches(profile: profile, screen: screen) {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
            if let matchingMode = modes.first(where: {
                Int($0.width) == profile.logicalWidth &&
                Int($0.height) == profile.logicalHeight &&
                Int($0.pixelWidth) == profile.pixelWidth &&
                Int($0.pixelHeight) == profile.pixelHeight
            }) {
                let result = CGDisplaySetDisplayMode(displayID, matchingMode, nil)
                if result == .success {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }

        let refreshedScreen = NSScreen.screens.first(where: { $0.displayID == displayID }) ?? screen
        guard modeMatches(profile: profile, screen: refreshedScreen) else {
            let bounds = CGDisplayBounds(displayID)
            let logicalWidth = Int(bounds.width.rounded())
            let logicalHeight = Int(bounds.height.rounded())
            let dimensions = capturePixelDimensions(
                displayID: displayID,
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight,
                fallbackScale: refreshedScreen?.backingScaleFactor ?? profile.scaleFactor
            )
            let expected = "\(profile.logicalWidth)×\(profile.logicalHeight) pt / \(profile.pixelWidth)×\(profile.pixelHeight) px"
            let actual = "\(logicalWidth)×\(logicalHeight) pt / \(dimensions.width)×\(dimensions.height) px"
            throw VirtualDisplayError.modeMismatch(expected: expected, actual: actual)
        }
    }

    private func modeMatches(profile: DisplayProfile, screen: NSScreen?) -> Bool {
        guard let displayID else { return false }
        let bounds = CGDisplayBounds(displayID)
        let logicalWidth = Int(bounds.width.rounded())
        let logicalHeight = Int(bounds.height.rounded())
        let dimensions = capturePixelDimensions(
            displayID: displayID,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            fallbackScale: screen?.backingScaleFactor ?? profile.scaleFactor
        )

        return logicalWidth == profile.logicalWidth &&
            logicalHeight == profile.logicalHeight &&
            dimensions.width == profile.pixelWidth &&
            dimensions.height == profile.pixelHeight
    }
}
