import AppKit
import CoreGraphics

struct DisplayProfile: Equatable {
    let displayID: CGDirectDisplayID
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let scaleFactor: CGFloat
    let refreshRate: Double
    let physicalSize: CGSize

    @MainActor
    static func currentBuiltIn() -> DisplayProfile? {
        guard let screen = NSScreen.screens.first(where: {
            guard let displayID = $0.displayID else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        }), let displayID = screen.displayID else {
            return nil
        }

        let logicalWidth = max(1, Int(screen.frame.width.rounded()))
        let logicalHeight = max(1, Int(screen.frame.height.rounded()))
        let pixelDimensions = capturePixelDimensions(
            displayID: displayID,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            fallbackScale: screen.backingScaleFactor
        )
        let modeRefreshRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        let refreshRate = modeRefreshRate >= 30 ? min(modeRefreshRate, 120) : 60

        var physicalSize = CGDisplayScreenSize(displayID)
        if physicalSize.width <= 0 || physicalSize.height <= 0 {
            let assumedPixelsPerInch: CGFloat = 220
            physicalSize = CGSize(
                width: CGFloat(pixelDimensions.width) / assumedPixelsPerInch * 25.4,
                height: CGFloat(pixelDimensions.height) / assumedPixelsPerInch * 25.4
            )
        }

        return DisplayProfile(
            displayID: displayID,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: pixelDimensions.width,
            pixelHeight: pixelDimensions.height,
            scaleFactor: screen.backingScaleFactor,
            refreshRate: refreshRate,
            physicalSize: physicalSize
        )
    }

    @MainActor
    var screen: NSScreen? {
        NSScreen.screens.first(where: { $0.displayID == displayID })
    }
}

func capturePixelDimensions(
    displayID: CGDirectDisplayID,
    logicalWidth: Int,
    logicalHeight: Int,
    fallbackScale: CGFloat
) -> (width: Int, height: Int) {
    if let mode = CGDisplayCopyDisplayMode(displayID) {
        var width = mode.pixelWidth
        var height = mode.pixelHeight

        let logicalIsLandscape = logicalWidth >= logicalHeight
        let pixelsAreLandscape = width >= height
        if logicalIsLandscape != pixelsAreLandscape {
            swap(&width, &height)
        }

        return (width, height)
    }

    return (
        max(1, Int((CGFloat(logicalWidth) * fallbackScale).rounded())),
        max(1, Int((CGFloat(logicalHeight) * fallbackScale).rounded()))
    )
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
