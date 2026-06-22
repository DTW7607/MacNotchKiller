import AppKit
import CoreGraphics
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum LifecycleState {
        case launching
        case selectingWindow
        case running
        case rebuilding
        case quitting
    }

    private var state: LifecycleState = .launching
    private var builtInProfile: DisplayProfile?
    private var virtualDisplayController: VirtualDisplayController?
    private var windowController: CaptureWindowController?
    private var captureSession: CaptureSession?
    private var inputRouter: InputRouter?
    private var windowSelector: WindowSelector?
    private var previousFrontmostApplication: NSRunningApplication?
    private var screenChangeTask: Task<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let currentApplicationPID = ProcessInfo.processInfo.processIdentifier
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != currentApplicationPID {
            previousFrontmostApplication = NSWorkspace.shared.frontmostApplication
        }

        configureMainMenu()
        configureSignalHandlers()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        Task { await launch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenChangeTask?.cancel()
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        NotificationCenter.default.removeObserver(self)

        inputRouter?.stop()
        inputRouter = nil
        windowSelector?.cancel()
        windowSelector = nil
        virtualDisplayController?.destroy()
        virtualDisplayController = nil
        NSApp.presentationOptions = []
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)

        let applicationMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "退出 FullScreenTools",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        applicationMenu.addItem(quitItem)

        applicationMenuItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
    }

    private func configureSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.shutdownAndTerminate()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func launch() async {
        guard VirtualDisplayController.isSupported else {
            showErrorAndTerminate(
                title: "不支持虚拟显示器",
                message: VirtualDisplayError.unsupported.localizedDescription
            )
            return
        }

        guard InputRouter.requestAccessibilityPermission() else {
            showErrorAndTerminate(
                title: "需要辅助功能权限",
                message: "完整键鼠透传需要全局输入权限。请在“系统设置 → 隐私与安全性 → 辅助功能”中允许终端或 FullScreenTools，然后重新运行程序。"
            )
            return
        }

        guard let profile = DisplayProfile.currentBuiltIn() else {
            showErrorAndTerminate(
                title: "没有内置显示器",
                message: "程序没有找到 CGDisplayIsBuiltin 标记的内置屏幕。"
            )
            return
        }

        do {
            state = .selectingWindow
            writeStatus("请移动鼠标选择窗口；蓝色外框出现后，点击窗口确认。\n")
            let targetWindow = try await selectWindow()
            targetWindow.focus()
            try await startRuntime(
                matching: profile,
                stateWhileStarting: .launching,
                windowToMove: targetWindow
            )
        } catch {
            await fail(with: error)
        }
    }

    private func startRuntime(
        matching profile: DisplayProfile,
        stateWhileStarting: LifecycleState,
        windowToMove: FocusedWindowHandle?
    ) async throws {
        state = stateWhileStarting
        builtInProfile = profile

        guard let builtInScreen = profile.screen else {
            throw CaptureSessionError.displayUnavailable
        }

        let virtualController = VirtualDisplayController()
        virtualController.unexpectedTerminationHandler = { [weak self, weak virtualController] in
            guard let self, let virtualController else { return }
            Task { @MainActor in
                guard self.virtualDisplayController === virtualController,
                      self.state == .running else {
                    return
                }
                await self.fail(
                    with: VirtualDisplayError.creationFailed("虚拟显示器被系统意外移除。")
                )
            }
        }
        virtualDisplayController = virtualController

        try virtualController.create(matching: profile)
        // CGVirtualDisplay 构造完成时，显示器 ID 已存在，但 WindowServer
        // 可能尚未允许该显示器参与布局。必须先等待 Online、Active、
        // NSScreen 注册和显示模式确认完成，否则排列会返回 1001
        //（kCGErrorIllegalArgument）。
        _ = try await virtualController.waitUntilReady(matching: profile)
        try virtualController.positionAtIsolatedCorner(
            ofAllDisplaysAligningWith: profile.displayID
        )

        guard let virtualDisplayID = virtualController.displayID else {
            throw VirtualDisplayError.creationFailed("虚拟显示器没有有效 ID。")
        }

        if let targetWindow = windowToMove {
            try targetWindow.moveToDisplay(virtualDisplayID)
            try targetWindow.enterFullScreen()
            // 原生全屏会创建/切换 Space。等待窗口完成过渡后再显示透传层，
            // 避免用户看到目标窗口在虚拟屏上的中间动画状态。
            try await Task.sleep(nanoseconds: 800_000_000)
        } else if stateWhileStarting == .launching {
            throw FocusedWindowError.noFocusedWindow
        }

        let controller: CaptureWindowController
        if let existingController = windowController {
            controller = existingController
        } else {
            controller = CaptureWindowController(screen: builtInScreen)
            windowController = controller
        }

        // 菜单栏保持系统默认行为；仅对本程序请求隐藏 Dock。目标窗口进入
        // 原生全屏后 Dock 会先由系统隐藏，InputRouter 再阻断所有常用唤出路径。
        NSApp.presentationOptions = [.hideDock]
        controller.show(on: builtInScreen)

        try await startCapture(displayID: virtualDisplayID)

        let router = InputRouter()
        router.delegate = self
        try router.start(
            virtualDisplayID: virtualDisplayID,
            builtInDisplayID: profile.displayID
        )
        inputRouter = router

        state = .running
    }

    private func selectWindow() async throws -> FocusedWindowHandle {
        try await withCheckedThrowingContinuation { continuation in
            let selector = WindowSelector(
                excludingProcessID: pid_t(ProcessInfo.processInfo.processIdentifier)
            )
            windowSelector = selector

            do {
                try selector.start { [weak self, weak selector] result in
                    if let self, self.windowSelector === selector {
                        self.windowSelector = nil
                    }
                    continuation.resume(with: result)
                }
            } catch {
                windowSelector = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func startCapture(displayID: CGDirectDisplayID) async throws {
        guard let captureView = windowController?.captureView else {
            throw CaptureSessionError.renderTargetUnavailable
        }

        if let oldSession = captureSession {
            await oldSession.stop()
            windowController?.captureView.resetImage()
        }

        let session = CaptureSession()
        session.delegate = self
        captureSession = session
        try await session.start(
            displayID: displayID,
            renderingOn: captureView
        )
    }

    @objc
    private func screenParametersDidChange() {
        guard state == .running else { return }

        screenChangeTask?.cancel()
        screenChangeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.handleScreenParametersChange()
        }
    }

    private func handleScreenParametersChange() async {
        guard state == .running else { return }
        guard let currentProfile = DisplayProfile.currentBuiltIn() else {
            await fail(with: CaptureSessionError.displayUnavailable)
            return
        }

        if currentProfile != builtInProfile {
            await rebuildRuntime(matching: currentProfile)
            return
        }

        guard let virtualController = virtualDisplayController,
              let virtualDisplayID = virtualController.displayID,
              CGDisplayIsOnline(virtualDisplayID) != 0 else {
            await fail(
                with: VirtualDisplayError.creationFailed("虚拟显示器已不在系统显示器列表中。")
            )
            return
        }

        do {
            try virtualController.positionAtIsolatedCorner(
                ofAllDisplaysAligningWith: currentProfile.displayID
            )
            inputRouter?.updateVirtualDisplay(virtualDisplayID)
            if let screen = currentProfile.screen {
                windowController?.show(on: screen)
            }
        } catch {
            await fail(with: error)
        }
    }

    private func rebuildRuntime(matching profile: DisplayProfile) async {
        guard state == .running else { return }
        let focusedWindow = FocusedWindowTracker.currentFocusedWindow(
            excludingProcessID: pid_t(ProcessInfo.processInfo.processIdentifier)
        )
        state = .rebuilding

        inputRouter?.stop()
        inputRouter = nil
        windowSelector?.cancel()
        windowSelector = nil
        await captureSession?.stop()
        captureSession = nil
        windowController?.captureView.resetImage()
        virtualDisplayController?.destroy()
        virtualDisplayController = nil

        do {
            try await startRuntime(
                matching: profile,
                stateWhileStarting: .rebuilding,
                windowToMove: focusedWindow
            )
        } catch {
            await fail(with: error)
        }
    }

    private func writeStatus(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    @objc
    private func quit() {
        Task { await shutdownAndTerminate() }
    }

    private func shutdownAndTerminate() async {
        guard state != .quitting else { return }
        state = .quitting
        screenChangeTask?.cancel()

        inputRouter?.stop()
        inputRouter = nil
        windowSelector?.cancel()
        windowSelector = nil
        await captureSession?.stop()
        captureSession = nil
        windowController?.close()
        windowController = nil
        NSApp.presentationOptions = []
        virtualDisplayController?.destroy()
        virtualDisplayController = nil

        previousFrontmostApplication?.activate(options: [.activateIgnoringOtherApps])
        NSApp.terminate(nil)
    }

    private func fail(with error: Error) async {
        guard state != .quitting else { return }
        state = .quitting
        screenChangeTask?.cancel()

        inputRouter?.stop()
        inputRouter = nil
        await captureSession?.stop()
        captureSession = nil
        windowController?.window?.orderOut(nil)
        windowController = nil
        NSApp.presentationOptions = []
        virtualDisplayController?.destroy()
        virtualDisplayController = nil

        previousFrontmostApplication?.activate(options: [.activateIgnoringOtherApps])
        showErrorAndTerminate(
            title: "虚拟屏透传已停止",
            message: error.localizedDescription,
            resourcesAlreadyCleaned: true
        )
    }

    private func showErrorAndTerminate(
        title: String,
        message: String,
        resourcesAlreadyCleaned: Bool = false
    ) {
        if !resourcesAlreadyCleaned {
            state = .quitting
            inputRouter?.stop()
            inputRouter = nil
            windowSelector?.cancel()
            windowSelector = nil
            windowController?.window?.orderOut(nil)
            NSApp.presentationOptions = []
            virtualDisplayController?.destroy()
            virtualDisplayController = nil
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: CaptureSessionDelegate {
    nonisolated func captureSession(_ session: CaptureSession, didStopWith error: Error) {
        Task { @MainActor [weak self] in
            await self?.fail(with: error)
        }
    }
}

extension AppDelegate: InputRouterDelegate {
    nonisolated func inputRouterRequestedExit(_ router: InputRouter) {
        Task { @MainActor [weak self] in
            await self?.shutdownAndTerminate()
        }
    }

    nonisolated func inputRouter(_ router: InputRouter, didFailWith message: String) {
        Task { @MainActor [weak self] in
            await self?.fail(
                with: InputRouterRuntimeError.monitorFailed(message)
            )
        }
    }
}

enum InputRouterRuntimeError: LocalizedError {
    case monitorFailed(String)

    var errorDescription: String? {
        switch self {
        case let .monitorFailed(message):
            return message
        }
    }
}
