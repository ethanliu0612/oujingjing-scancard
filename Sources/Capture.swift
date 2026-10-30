import AppKit
import CoreGraphics
import ScreenCaptureKit

struct DisplayShot {
    let image: CGImage
    let displayID: CGDirectDisplayID
    /// 该显示器在全局坐标系（左上角原点、y 向下）中的矩形，单位为点。
    let frame: CGRect
    /// 物理像素 / 逻辑点
    let scale: CGFloat

    func crop(cgRect: CGRect) -> CGImage? {
        let local = CGRect(x: cgRect.minX - frame.minX,
                           y: cgRect.minY - frame.minY,
                           width: cgRect.width,
                           height: cgRect.height)
        let clipped = local.intersection(CGRect(x: 0, y: 0,
                                                width: CGFloat(image.width) / scale,
                                                height: CGFloat(image.height) / scale))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        let pixelRect = CGRect(x: (clipped.minX * scale).rounded(.down),
                               y: (clipped.minY * scale).rounded(.down),
                               width: (clipped.width * scale).rounded(.up),
                               height: (clipped.height * scale).rounded(.up))
        let bounded = pixelRect.intersection(CGRect(x: 0, y: 0,
                                                    width: CGFloat(image.width),
                                                    height: CGFloat(image.height)))
        guard !bounded.isNull, bounded.width >= 2, bounded.height >= 2 else { return nil }
        return image.cropping(to: bounded.integral)
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case emptyRegion
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有屏幕录制权限"
        case .noDisplay:
            return "找不到对应的显示器"
        case .emptyRegion:
            return "选区太小了"
        case .underlying(let message):
            return message
        }
    }
}

enum Capture {
    static func requestPermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    /// 一次性抓取所有显示器画面。框选期间用它做放大镜与最终裁切，避免二次抓屏导致闪烁。
    static func allDisplays() async throws -> [DisplayShot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
        guard !content.displays.isEmpty else { throw CaptureError.permissionDenied }

        var shots: [DisplayShot] = []
        for display in content.displays {
            do {
                let shot = try await capture(display: display)
                shots.append(shot)
            } catch {
                Log.write("capture display \(display.displayID) failed: \(error)")
            }
        }
        if shots.isEmpty { throw CaptureError.permissionDenied }
        return shots
    }

    private static func capture(display: SCDisplay) async throws -> DisplayShot {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        let pixelWidth = CGDisplayPixelsWide(display.displayID)
        let pixelHeight = CGDisplayPixelsHigh(display.displayID)
        config.width = max(pixelWidth, Int(display.width))
        config.height = max(pixelHeight, Int(display.height))

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let scale = display.frame.width > 0 ? CGFloat(cgImage.width) / display.frame.width : 2.0
        return DisplayShot(image: cgImage, displayID: display.displayID,
                           frame: display.frame, scale: max(scale, 1.0))
    }

    /// 主屏（原点为 0,0 的那块屏）高度，用于 AppKit 与 CoreGraphics 坐标系互转。
    static var primaryScreenHeight: CGFloat {
        let screens = NSScreen.screens
        let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
        return primary?.frame.height ?? 0
    }

    /// AppKit 全局坐标（左下角原点）→ CoreGraphics 全局坐标（左上角原点）
    static func toCGGlobal(_ appKitRect: CGRect) -> CGRect {
        let h = primaryScreenHeight
        return CGRect(x: appKitRect.minX,
                      y: h - appKitRect.maxY,
                      width: appKitRect.width,
                      height: appKitRect.height)
    }
}
