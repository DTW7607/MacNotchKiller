import AppKit
import IOSurface
import Metal
import QuartzCore

final class CaptureView: NSView {
    private let metalLayer = CAMetalLayer()
    private let metalDevice: MTLDevice
    private let commandQueue: MTLCommandQueue

    override init(frame frameRect: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("当前设备无法创建 Metal 渲染上下文")
        }
        metalDevice = device
        self.commandQueue = commandQueue

        super.init(frame: frameRect)

        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        // 画面通过 blit encoder 写入 drawable；framebufferOnly 必须关闭。
        metalLayer.framebufferOnly = false
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        layer = metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func layout() {
        super.layout()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    /// 把 CGDisplayStream 提供的 IOSurface 直接映射为 Metal 纹理。
    /// Surface 使用计数直到 GPU 命令结束后才释放，防止 WindowServer 过早复用。
    func render(surface: IOSurfaceRef) {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let sourceTexture = metalDevice.makeTexture(
            descriptor: descriptor,
            iosurface: surface,
            plane: 0
        ) else {
            return
        }

        if metalLayer.drawableSize.width != CGFloat(width) ||
            metalLayer.drawableSize.height != CGFloat(height) {
            metalLayer.drawableSize = CGSize(width: width, height: height)
        }

        guard let drawable = metalLayer.nextDrawable(),
              drawable.texture.width == width,
              drawable.texture.height == height,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        IOSurfaceIncrementUseCount(surface)
        encoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in
            IOSurfaceDecrementUseCount(surface)
        }
        commandBuffer.commit()
    }

    func resetImage() {
        metalLayer.backgroundColor = NSColor.black.cgColor
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
