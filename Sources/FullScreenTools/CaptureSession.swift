import AppKit
import CoreGraphics
import VirtualDisplayBridge

protocol CaptureSessionDelegate: AnyObject {
    func captureSession(_ session: CaptureSession, didStopWith error: Error)
}

enum CaptureSessionError: LocalizedError {
    case displayUnavailable
    case renderTargetUnavailable
    case directStreamUnsupported
    case directStreamStopped

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "虚拟显示器已不可用。"
        case .renderTargetUnavailable:
            return "用于显示虚拟屏画面的 Metal 输出层不可用。"
        case .directStreamUnsupported:
            return "当前 macOS 已移除 CGDisplayStream 运行时接口，无法直接读取虚拟显示器的 IOSurface。"
        case .directStreamStopped:
            return "WindowServer 已停止虚拟显示器的直接 IOSurface 流。"
        }
    }
}

/// 按虚拟显示器 ID 直接接收 WindowServer 的 IOSurface。
///
/// 这里不枚举窗口、不排除进程，也不使用 ScreenCaptureKit。透传窗口位于
/// 内置屏，因此它本来就不会出现在虚拟显示器的合成结果中。
final class CaptureSession: NSObject {
    weak var delegate: CaptureSessionDelegate?

    private let outputQueue = DispatchQueue(
        label: "FullScreenTools.display-surface",
        qos: .userInteractive
    )
    private weak var captureView: CaptureView?
    private var stream: FSTDisplayStream?
    private let stateLock = NSLock()
    private var expectedStop = false

    @MainActor
    func start(
        displayID: CGDirectDisplayID,
        renderingOn captureView: CaptureView
    ) async throws {
        guard CGDisplayIsOnline(displayID) != 0,
              CGDisplayIsActive(displayID) != 0 else {
            throw CaptureSessionError.displayUnavailable
        }
        guard FSTDisplayStream.isSupported else {
            throw CaptureSessionError.directStreamUnsupported
        }

        let bounds = CGDisplayBounds(displayID)
        let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        let dimensions = capturePixelDimensions(
            displayID: displayID,
            logicalWidth: max(1, Int(bounds.width.rounded())),
            logicalHeight: max(1, Int(bounds.height.rounded())),
            fallbackScale: screen?.backingScaleFactor ?? 2
        )
        let detectedRefreshRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        let refreshRate = detectedRefreshRate >= 30
            ? min(120, detectedRefreshRate)
            : 60

        self.captureView = captureView
        setExpectedStop(false)

        let stream = try FSTDisplayStream(
            displayID: displayID,
            outputWidth: dimensions.width,
            outputHeight: dimensions.height,
            refreshRate: refreshRate,
            queue: outputQueue
        ) { [weak self] status, _, surface in
            guard let self else { return }

            switch status {
            case .complete:
                guard let surface, let captureView = self.captureView else { return }
                captureView.render(surface: surface)
            case .stopped:
                guard !self.isExpectedStop() else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.captureSession(
                        self,
                        didStopWith: CaptureSessionError.directStreamStopped
                    )
                }
            case .idle, .blank:
                break
            @unknown default:
                break
            }
        }

        self.stream = stream
        do {
            try stream.start()
        } catch {
            self.stream = nil
            throw error
        }
    }

    @MainActor
    func stop() async {
        guard let stream else { return }
        setExpectedStop(true)
        stream.stop()
        self.stream = nil
        captureView = nil
    }

    private func setExpectedStop(_ value: Bool) {
        stateLock.lock()
        expectedStop = value
        stateLock.unlock()
    }

    private func isExpectedStop() -> Bool {
        stateLock.lock()
        let value = expectedStop
        stateLock.unlock()
        return value
    }
}
