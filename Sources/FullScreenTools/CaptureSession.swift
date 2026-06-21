import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

protocol CaptureSessionDelegate: AnyObject {
    func captureSession(_ session: CaptureSession, didStopWith error: Error)
}

enum CaptureSessionError: LocalizedError {
    case displayUnavailable
    case selfExclusionUnavailable

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            return "所选显示器已不可用。"
        case .selfExclusionUnavailable:
            return "无法识别本程序的窗口，已停止捕获以避免产生递归画面。"
        }
    }
}

final class CaptureSession: NSObject {
    weak var delegate: CaptureSessionDelegate?

    private let outputQueue = DispatchQueue(
        label: "FullScreenTools.capture-output",
        qos: .userInteractive
    )
    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var stream: SCStream?
    private let stateLock = NSLock()
    private var expectedStop = false

    @MainActor
    func start(
        displayID: CGDirectDisplayID,
        excluding window: NSWindow,
        renderingOn displayLayer: AVSampleBufferDisplayLayer
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureSessionError.displayUnavailable
        }

        let pixelDimensions = capturePixelDimensions(
            displayID: displayID,
            logicalWidth: display.width,
            logicalHeight: display.height,
            fallbackScale: window.screen?.backingScaleFactor ?? 1
        )

        let processID = pid_t(ProcessInfo.processInfo.processIdentifier)
        // 不能排除整个 com.apple.dock：Dock 进程还负责桌面/Space 背景层。
        // 虚拟屏上没有普通窗口时，排除它会让捕获结果只剩黑色。
        let excludedApplications = content.applications.filter { application in
            application.processID == processID
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = false
        }

        let configuration = SCStreamConfiguration()
        configuration.width = pixelDimensions.width
        configuration.height = pixelDimensions.height
        let detectedRefreshRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        let captureFrameRate: Int32 = detectedRefreshRate >= 30
            ? max(30, min(120, Int32(detectedRefreshRate.rounded())))
            : 60
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: captureFrameRate)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.showsCursor = true
        configuration.queueDepth = 3
        configuration.capturesAudio = false

        // backgroundColor 在 ScreenCaptureKit 中是非持有的 CGColorRef。这里保留
        // 系统默认值，避免临时 CGColor 在配置被复制前释放。窗口和显示层负责黑底。

        self.displayLayer = displayLayer
        setExpectedStop(false)

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: outputQueue
        )

        self.stream = stream
        try await stream.startCapture()
    }

    @MainActor
    func stop() async {
        guard let stream else { return }

        setExpectedStop(true)
        do {
            try await stream.stopCapture()
        } catch {
            // 退出或重建捕获期间，即使流已由系统停止，也继续清理本地状态。
        }
        self.stream = nil
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

extension CaptureSession: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard
            outputType == .screen,
            CMSampleBufferIsValid(sampleBuffer),
            CMSampleBufferDataIsReady(sampleBuffer),
            CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
            let displayLayer
        else {
            return
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}

extension CaptureSession: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isExpectedStop() else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.captureSession(self, didStopWith: error)
        }
    }
}
