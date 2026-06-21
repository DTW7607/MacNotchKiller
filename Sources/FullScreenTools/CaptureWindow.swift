import AppKit
import AVFoundation
import QuartzCore

final class CaptureView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func resetImage() {
        displayLayer.flushAndRemoveImage()
    }
}

final class CaptureWindowController: NSWindowController {
    let captureView: CaptureView

    init(screen: NSScreen) {
        captureView = CaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.contentView = captureView
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .screenSaver
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    func show(on screen: NSScreen) {
        guard let window else { return }

        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }
}
