import AppKit
import CoreGraphics

/// 启动阶段的窗口选择器。
///
/// Event Tap 只负责观察移动和截获确认点击；蓝色边框窗口忽略鼠标事件，
/// 不会激活本程序，也不会改变目标应用的焦点。
@MainActor
final class WindowSelector {
    private struct Candidate {
        let windowID: CGWindowID
        let bounds: CGRect
        let handle: FocusedWindowHandle
    }

    private let excludedProcessID: pid_t
    private let highlightPanel: NSPanel
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hoveredCandidate: Candidate?
    private var pressedCandidate: Candidate?
    private var lastHitTestUptime: TimeInterval = 0
    private var completion: ((Result<FocusedWindowHandle, Error>) -> Void)?

    init(excludingProcessID: pid_t) {
        self.excludedProcessID = excludingProcessID

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]

        let borderView = NSView(frame: .zero)
        borderView.wantsLayer = true
        borderView.layer?.backgroundColor = NSColor.clear.cgColor
        borderView.layer?.borderColor = NSColor.systemBlue.cgColor
        borderView.layer?.borderWidth = 4
        borderView.layer?.cornerRadius = 7
        panel.contentView = borderView
        highlightPanel = panel
    }

    func start(
        completion: @escaping (Result<FocusedWindowHandle, Error>) -> Void
    ) throws {
        guard eventTap == nil else { return }
        self.completion = completion

        let mask = Self.eventMask(for: [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp
        ])

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.completion = nil
            throw FocusedWindowError.selectionMonitorUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        ) else {
            CFMachPortInvalidate(tap)
            self.completion = nil
            throw FocusedWindowError.selectionMonitorUnavailable
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        if let location = CGEvent(source: nil)?.location {
            updateHoveredWindow(at: location)
        }
    }

    func cancel() {
        finish(with: .failure(FocusedWindowError.selectionCancelled))
    }

    nonisolated private static let eventTapCallback: CGEventTapCallBack = {
        _,
        type,
        event,
        userInfo
    in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let selector = Unmanaged<WindowSelector>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return MainActor.assumeIsolated {
            selector.handle(type: type, event: event)
        }
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard let eventTap else { return nil }
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                finish(with: .failure(FocusedWindowError.selectionMonitorUnavailable))
            }
            return nil
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            updateHoveredWindow(at: event.location)
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            // 点击时重新命中，避免快速移动后使用上一帧的悬停窗口。
            updateHoveredWindow(at: event.location, force: true)
            guard let hoveredCandidate else {
                return Unmanaged.passUnretained(event)
            }
            pressedCandidate = hoveredCandidate
            // 按下和释放会成对拦截，避免目标应用收到不完整的点击事件。
            return nil

        case .leftMouseUp:
            guard let pressedCandidate else {
                return Unmanaged.passUnretained(event)
            }
            self.pressedCandidate = nil
            updateHoveredWindow(at: event.location, force: true)
            guard hoveredCandidate?.windowID == pressedCandidate.windowID else {
                return nil
            }
            finish(with: .success(pressedCandidate.handle))
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func updateHoveredWindow(at location: CGPoint, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastHitTestUptime < (1.0 / 30.0) {
            return
        }
        lastHitTestUptime = now

        guard let candidate = candidate(at: location) else {
            hoveredCandidate = nil
            highlightPanel.orderOut(nil)
            return
        }

        let needsLayout = hoveredCandidate?.windowID != candidate.windowID ||
            hoveredCandidate?.bounds != candidate.bounds
        hoveredCandidate = candidate
        guard needsLayout else { return }

        // CG/AX 使用左上原点，AppKit 窗口坐标使用左下原点。
        let appKitBounds = Self.appKitRect(fromQuartzRect: candidate.bounds)
        let borderWidth: CGFloat = 4
        highlightPanel.setFrame(
            appKitBounds.insetBy(dx: -borderWidth, dy: -borderWidth),
            display: true
        )
        highlightPanel.orderFrontRegardless()
    }

    private func candidate(at location: CGPoint) -> Candidate? {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements
        ]
        guard let windowList = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // CGWindowList 按前到后排列；第一个可映射到 AXWindow 的命中项
        // 就是鼠标下方实际可选择的顶层窗口。
        for info in windowList {
            guard let ownerNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                  ) else {
                continue
            }

            let ownerPID = pid_t(ownerNumber.int32Value)
            guard ownerPID != 0,
                  ownerPID != excludedProcessID,
                  layerNumber.intValue == 0,
                  bounds.width >= 40,
                  bounds.height >= 40,
                  bounds.contains(location) else {
                continue
            }

            if let alpha = info[kCGWindowAlpha as String] as? NSNumber,
               alpha.doubleValue <= 0 {
                continue
            }

            let title = info[kCGWindowName as String] as? String
            guard let handle = FocusedWindowTracker.window(
                ownerPID: ownerPID,
                matching: bounds,
                title: title,
                containing: location
            ) else {
                continue
            }

            return Candidate(
                windowID: CGWindowID(windowNumber.uint32Value),
                bounds: bounds,
                handle: handle
            )
        }
        return nil
    }

    private func finish(with result: Result<FocusedWindowHandle, Error>) {
        guard let completion else { return }
        self.completion = nil
        stop()

        // 避免在 Event Tap 回调栈内直接启动虚拟显示器和 Space 切换。
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func stop() {
        highlightPanel.orderOut(nil)
        hoveredCandidate = nil
        pressedCandidate = nil

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private static func appKitRect(fromQuartzRect rect: CGRect) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: primaryScreen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func eventMask(for types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }
}
